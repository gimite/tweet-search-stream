# coding: utf-8

# Copyright: Hiroshi Ichikawa <http://gimite.net/en/>
# License: New BSD License

$KCODE = "u"

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

require "moji"
require "tss_config"


class TSSWebServer < Sinatra::Base
    
    COOKIE_KEY = "session"
    
    set(:port, TSSConfig::WEB_SERVER_PORT)
    set(:environment, TSSConfig::SINATRA_ENVIRONMENT)
    set(:public, "./public")
    set(:logging, true)
    
    helpers() do
      include(ERB::Util)
    end

    before() do
      session_id = request.cookies[COOKIE_KEY]
      @session = session_id ? Session.get(session_id) : nil
      @session ||= Session.new()
      response.set_cookie(COOKIE_KEY,
          {:value => @session.id, :expires => Time.now + 3 * 30 * 24 * 3600})
      @twitter = get_twitter(@session[:access_token], @session[:access_token_secret])
    end
    
    get("/") do
      buzz_words = get_buzz_words("en")
      query = params[:q] || buzz_words.grep(/^\#\S+$/)[0] || buzz_words[0] || ""
      search(query, true)
    end

    get("/search") do
      query = params[:q] || ""
      search(query, false)
    end
    
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
    
    get("/buzz") do
      result = []
      for (lang_id, lang_name) in [["en", "English"], ["ja", "Japanese"]]
        words = get_buzz_words(lang_id)
        if lang_id == "ja"
          words = words.grep(/^\#/)
        end
        words = words[0, 10]
        result.push({"lang_id" => lang_id, "lang_name" => lang_name, "words" => words})
      end
      content_type("text/javascript", :charset => "utf-8")
      return JSON.dump(result)
    end

    get("/logout") do
      @session.clear()
      redirect("/")
    end
    
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
      return OAuth::Consumer.new(TSSConfig::TWITTER_API_KEY, TSSConfig::TWITTER_API_SECRET, :site => "http://twitter.com")
    end

    def search(query, index)
      if @twitter
        @query = query
        @query_json = JSON.dump([@query])
        @index = index
        @web_socket_url = "ws://%s:%d/" % [URI.parse(TSSConfig::BASE_URL).host, TSSConfig::WEB_SOCKET_SERVER_PORT]
        @screen_name = @session[:screen_name]
        @unsupported_query = @query =~ /#{Moji.kana}|#{Moji.kanji}/
        @title = params[:title]
        @logo_url = params[:logo]
        erb(:search)
      else
        @current_url = request.path + (request.query_string.empty? ? "" : "?" + request.query_string)
        erb(:login_form)
      end
    end
    
    def get_buzz_words(lang_id)
      rss = RSS::Parser.parse(open("http://buzztter.com/#{lang_id}/rss"){ |f| f.read() })
      return rss.items.map(){ |t| t.title }
    end
    
end
