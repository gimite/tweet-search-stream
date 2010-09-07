#!/usr/bin/env ruby
# coding: utf-8

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

require "tss_config"


class TSSWebServer < Sinatra::Base

    set(:public, "./public")
    
    helpers() do
      include(ERB::Util)
    end

    before() do
      
      session_id = request.cookies["real_time_tweets_session"]
      @session = session_id ? Session.get(session_id) : nil
      if !@session
        @session ||= Session.new()
        Session.save()
      end
      response.set_cookie("real_time_tweets_session",
          {:value => @session.id, :expires => Time.now + 3 * 30 * 24 * 3600})
      
      if @session[:access_token]
        twitter_oauth = Twitter::OAuth.new(TWITTER_API_KEY, TWITTER_API_SECRET)
        twitter_oauth.authorize_from_access(
          @session[:access_token], @session[:access_token_secret])
        @twitter = Twitter::Base.new(twitter_oauth)
      else
        @twitter = nil
      end
      
    end

    def base_url
      default_port = request.scheme == "http" ? 80 : 443
      port = request.port == default_port ? "" : ":#{request.port}"
      return "#{request.scheme}://#{request.host}#{port}"
    end

    def oauth_consumer
      return OAuth::Consumer.new(TWITTER_API_KEY, TWITTER_API_SECRET, :site => "http://twitter.com")
    end

    get("/") do
      query = params[:q] || get_buzz_words("en")[0] || ""
      search(query)
    end

    get("/search") do
      query = params[:q] || ""
      search(query)
    end
    
    get("/login") do
      callback_url = "#{base_url}/oauth_callback?redirect=" + CGI.escape(params[:redirect] || "")
      request_token = oauth_consumer.get_request_token(:oauth_callback => callback_url)
      @session[:request_token] = request_token.token
      @session[:request_token_secret] = request_token.secret
      Session.save()
      redirect(request_token.authorize_url)
    end

    get("/oauth_callback") do
      request_token = OAuth::RequestToken.new(
        oauth_consumer, @session[:request_token], @session[:request_token_secret])
      begin
        @access_token = request_token.get_access_token(
          {},
          :oauth_token => params[:oauth_token],
          :oauth_verifier => params[:oauth_verifier])
      rescue OAuth::Unauthorized => @exception
        return erb %{ oauth failed: <%=h @exception.message %> }
      end
      @session[:access_token] = @access_token.token
      @session[:access_token_secret] = @access_token.secret
      Session.save()
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
      Session.save()
      return "ok"
    end

    def search(query)
      if @twitter
        @query = query
        @query_json = JSON.dump([@query])
        erb(:search)
      else
        current_url = request.path + (request.query_string.empty? ? "" : "?" + request.query_string)
        @login_url = "/login?redirect=" + CGI.escape(current_url)
        erb(:login_form)
      end
    end
    
    def get_buzz_words(lang_id)
      rss = RSS::Parser.parse(open("http://buzztter.com/#{lang_id}/rss"){ |f| f.read() })
      return rss.items.map(){ |t| t.title }
    end
    
end
