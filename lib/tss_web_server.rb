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
require "em-http"

require "moji"
require "tss_config"
require "tss_helper"


class TSSWebServer < Sinatra::Base
    
    include(TSSHelper)
    include(ERB::Util)
    
    set(:port, TSSConfig::WEB_SERVER_PORT)
    set(:environment, TSSConfig::SINATRA_ENVIRONMENT)
    set(:public, "./public")
    set(:logging, true)
    register(Sinatra::Async)
    
=begin
    before() do
      session_id = request.cookies[TSSConfig::SESSION_COOKIE_KEY]
      @session = session_id ? Session.get(session_id) : nil
      @session ||= Session.new()
      response.set_cookie(TSSConfig::SESSION_COOKIE_KEY,
          {:value => @session.id, :path => "/", :expires => Time.now + 3 * 30 * 24 * 3600})
      @twitter = get_twitter(@session[:access_token], @session[:access_token_secret])
    end
=end

    aget("/") do
      get_buzz_words("en") do |buzz_words|
        buzz_words ||= []
        query = params[:q] || buzz_words.grep(/^\#\S+$/)[0] || buzz_words[0] || ""
        body(search(query, true))
        LOGGER.info("[web] GET /")
      end
    end

    get("/search") do
      query = params[:q] || ""
      return search(query, false)
    end
    
=begin
    post("/login") do
      callback_url = "#{TSSConfig::BASE_URL}/oauth_callback?redirect=" + CGI.escape(params[:redirect] || "")
      request_token = self.oauth_consumer.get_request_token(:oauth_callback => callback_url)
      @session.data = {
        :request_token => request_token.token,
        :request_token_secret => request_token.secret,
      }
      redirect(request_token.authorize_url)
    end

    get("/oauth_callback") do
      request_token = OAuth::RequestToken.new(
        self.oauth_consumer, @session[:request_token], @session[:request_token_secret])
      begin
        @access_token = request_token.get_access_token(
          {},
          :oauth_token => params[:oauth_token],
          :oauth_verifier => params[:oauth_verifier])
      rescue OAuth::Unauthorized => @exception
        return erb %{ Authentication failed: <%=h @exception.message %> }
      end
      @twitter = get_twitter(@access_token.token, @access_token.secret)
      @session.data = {
        :access_token => @access_token.token,
        :access_token_secret => @access_token.secret,
        :screen_name => @twitter.verify_credentials().screen_name,
      }
      if params[:redirect] && params[:redirect] =~ /\A\//
        redirect(params[:redirect])
      else
        redirect("/")
      end
    end
=end
    
    aget("/buzz") do
      result = []
      add_result = proc() do |lang_id, lang_name, &block|
        get_buzz_words(lang_id) do |words|
          words = (words || []).grep(/^\#[a-zA-Z0-9_]+$/)[0, 10]
          result.push({"lang_id" => lang_id, "lang_name" => lang_name, "words" => words})
          block.call()
        end
      end
      add_result.call("en", "English") do
        add_result.call("ja", "Japanese") do
          content_type("text/javascript", :charset => "utf-8")
          body(JSON.dump(result))
          LOGGER.info("[web] GET /buzz")
        end
      end
    end
    
=begin
    get("/logout") do
      @session.clear()
      redirect("/")
    end
=end
    
    get("/css/default.css") do
      @webkit = request.user_agent =~ /AppleWebKit/
      content_type("text/css")
      erb(:"default.css")
    end

    def get_twitter(access_token, access_token_secret)
      if access_token
        twitter_oauth = Twitter::OAuth.new(TSSConfig::TWITTER_API_KEY, TSSConfig::TWITTER_API_SECRET)
        twitter_oauth.authorize_from_access(access_token, access_token_secret)
        return Twitter::Base.new(twitter_oauth)
      else
        return nil
      end
    end

    def oauth_consumer
      return OAuth::Consumer.new(
        TSSConfig::TWITTER_API_KEY,
        TSSConfig::TWITTER_API_SECRET,
        :site => "http://twitter.com")
    end

    def search(query, index)
      @query = query
      @query_json = JSON.dump([@query])
      @index = index
      @web_socket_url = "ws://%s:%d/" %
        [URI.parse(TSSConfig::BASE_URL).host, TSSConfig::WEB_SOCKET_SERVER_PORT]
#      @screen_name = @session[:screen_name]
      @unsupported_query = @query =~ /#{Moji.kana}|#{Moji.kanji}/
      @title = params[:title]
      @logo_url = params[:logo]
      return erb(:search)
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
    
end
