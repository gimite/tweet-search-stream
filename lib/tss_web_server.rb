# coding: utf-8

# Copyright: Hiroshi Ichikawa <http://gimite.net/en/>
# License: New BSD License

$KCODE = "u" if RUBY_VERSION < "1.9.0"

require "securerandom"
require "net/http"
require "pp"
require "cgi"
require "time"
require "enumerator"
require "rss"
require "open-uri"

require "rubygems"
require "json"
require "oauth"
require "twitter"
require "sinatra/base"
require "sinatra/async"
require "sinatra/reloader"
require "em-http"
require "http_accept_language"

require "moji"
require "tss_config"
require "tss_helper"


Sinatra::Request.send(:include, HttpAcceptLanguage)


class TSSWebServer < Sinatra::Base
    
    include(TSSHelper)
    include(ERB::Util)
    
    HASH_TAG_EXP = /^\#[a-zA-Z0-9_]+$/
    
    set(:port, TSSConfig::WEB_SERVER_PORT)
    set(:environment, TSSConfig::SINATRA_ENVIRONMENT)
    set(:public, "./public")
    set(:logging, true)
    use(Rack::Session::Cookie, {
      :key => TSSConfig::SESSION_COOKIE_KEY,
      :path => "/",
      :expire_after => 3 * 30 * 24 * 3600,
      # Reuses Twitter key. Anything secret is fine.
      :secret => TSSConfig::TWITTER_API_WRITE_SECRET,
    })
    register(Sinatra::Async)
    configure(:development) do
      register(Sinatra::Reloader)
    end
    
    before() do
      @twitter = get_twitter(session[:access_token], session[:access_token_secret])
      @lang = params[:hl]
      if !@lang && ["/", "/search", "/js/search.js"].include?(request.path)
        @lang = request.compatible_language_from(["en", "ja"]) || "en"
        redirect(TSSConfig::BASE_URL + to_url(request, {"hl" => @lang}))
      end
    end
    
    aget("/") do
      get_buzz_words("en") do |buzz_words|
        buzz_words ||= []
        query = params[:q] || buzz_words.grep(/^\#\S+$/)[0] || buzz_words[0] || ""
        content_type("text/html", :charset => "utf-8")
        body(search(query, :search, true))
        LOGGER.info("[web] GET /")
      end
    end

    get("/search") do
      query = params[:q] || ""
      return search(query, :search, false)
    end
    
    get("/ustream") do
      channel = params[:channel]
      info = JSON.load(
        open("http://api.ustream.tv/json/channel/%s/getInfo" % CGI.escape(channel)){ |f| f.read() })
      @channel_id = info["results"]["id"]
      query = info["results"]["socialStream"]["hashtag"]
      return search(query, :ustream, false)
    end
    
    post("/login") do
      callback_url =
        "#{TSSConfig::BASE_URL}/oauth_callback?redirect=" + CGI.escape(params[:redirect] || "")
      request_token = self.oauth_consumer.get_request_token(:oauth_callback => callback_url)
      session[:request_token] = request_token.token
      session[:request_token_secret] = request_token.secret
      redirect(request_token.authorize_url)
    end

    get("/oauth_callback") do
      request_token = OAuth::RequestToken.new(
        self.oauth_consumer, session[:request_token], session[:request_token_secret])
      begin
        @access_token = request_token.get_access_token(
          {},
          :oauth_token => params[:oauth_token],
          :oauth_verifier => params[:oauth_verifier])
      rescue OAuth::Unauthorized => @exception
        return erubis(%{ Authentication failed: <%=h @exception.message %> })
      end
      @twitter = get_twitter(@access_token.token, @access_token.secret)
      session[:access_token] = @access_token.token
      session[:access_token_secret] = @access_token.secret
      session[:screen_name] = @twitter.verify_credentials().screen_name
      if params[:redirect] && params[:redirect] =~ /\A\//
        redirect(TSSConfig::BASE_URL + params[:redirect])
      else
        redirect(TSSConfig::BASE_URL + "/")
      end
    end
    
    post("/update") do
      @twitter.update(params[:status])
      return "ok"
    end
    
    aget("/buzz") do
      get_result = proc() do |lang_id, lang_name, &block|
        get_buzz_words(lang_id) do |words|
          words = (words || []).grep(HASH_TAG_EXP)[0, 10]
          block.call({"lang_id" => lang_id, "lang_name" => lang_name, "words" => words})
        end
      end
      get_result.call("en", "English") do |en_result|
        get_result.call("ja", "Japanese") do |ja_result|
          content_type("text/javascript", :charset => "utf-8")
          all_result = @lang == "ja" ? [ja_result, en_result] : [en_result, ja_result]
          body(JSON.dump(all_result))
          LOGGER.info("[web] GET /buzz")
        end
      end
    end
    
    get("/logout") do
      session.clear()
      redirect("%s/?hl=%s" % [TSSConfig::BASE_URL, @lang])
    end
    
    get("/css/default.css") do
      @webkit = request.user_agent =~ /AppleWebKit/
      content_type("text/css")
      erubis(:"default.css")
    end

    get("/js/search.js") do
      content_type("text/javascript")
      erubis(:"search.js")
    end

    def get_twitter(access_token, access_token_secret)
      if access_token && access_token_secret
        return Twitter::Client.new({
          :consumer_key => TSSConfig::TWITTER_API_WRITE_KEY,
          :consumer_secret => TSSConfig::TWITTER_API_WRITE_SECRET,
          :oauth_token => access_token,
          :oauth_token_secret => access_token_secret,
        })
      else
        return nil
      end
    end

    def oauth_consumer
      return OAuth::Consumer.new(
        TSSConfig::TWITTER_API_WRITE_KEY,
        TSSConfig::TWITTER_API_WRITE_SECRET,
        :site => "http://twitter.com")
    end

    def search(query, template, index)
      
      @query = query.force_encoding(Encoding::UTF_8)
      @index = index
      web_socket_url = "ws://%s:%d/" %
        [URI.parse(TSSConfig::BASE_URL).host, TSSConfig::WEB_SOCKET_SERVER_PORT]
      @screen_name = session[:screen_name]
      @support_update = @query =~ HASH_TAG_EXP
      @show_update = params[:show_update]
      @show_update_url = to_url(request, {"show_update" => "true"})
      @another_lang_url = to_url(request, {"hl" => @lang == "ja" ? "en" : "ja"})
      
      if params[:title]
        @head_title = @body_title = params[:title]
      elsif !@query.empty? && !index
        @head_title = "%s - Tweet Search Stream" % @query
        @body_title = "Tweet Search Stream"
      else
        @head_title = @body_title = "Tweet Search Stream"
      end
      @logo_url = params[:logo]
      
      @js_vars_json = JSON.dump({
        "query" => @query,
        "lang" => @lang,
        "web_socket_url" => web_socket_url,
      })
      return erubis(template)
      
    end
    
    def get_buzz_words(lang_id, &block)
      http = EventMachine::HttpRequest.new("http://buzztter.com/#{lang_id}/rss").get()
      http.callback() do
        never_die() do
          if http.response_header.status == 200
            rss = RSS::Parser.parse(http.response)
            yield(rss.items.map(){ |t| t.title })
          else
            LOGGER.error("[web] Buzztter fetch failed: status=%p" % http.response_header.status)
            yield(nil)
          end
        end
      end
      http.errback() do
        never_die() do
          LOGGER.error("[web] Buzztter fetch failed: connection error")
          yield(nil)
        end
      end
    end
    
    def to_url(request, params)
      return "%s?%s" % [
        request.path,
        request.params.merge(params).
          map(){ |k, v| CGI.escape(k) + "=" + CGI.escape(v || "") }.join("&"),
      ]
    end
    
end
