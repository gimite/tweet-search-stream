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
require "logger"
require "uri"

require "rubygems"
require "json"
require "oauth"
require "twitter"

require "web_socket"
require "tss_config"
require "session"
require "tss_web_server"


class TSSWebSocketServer
    
    def initialize(logger = nil, test_only = false)
      @logger = logger || Logger.new(STDERR)
      if !test_only
        params = {
          :accepted_domains => URI.parse(BASE_URL).host,
          :port => WEB_SOCKET_SERVER_PORT,
        }
        @server = WebSocketServer.new(params)
        @logger.info("WebSocket Server is running: %p" % params)
      end
    end
    
    def run()
      @server.run() do |ws|
        @logger.info("Connection accepted: #{ws.object_id}")
        @logger.info("Path: #{ws.path}, Origin: #{ws.origin}")
        uri = URI.parse(ws.path)
        params = CGI.parse(uri.query)
        if uri.path == "/" && !params["q"].empty?
          ws.handshake()
          cookie = {}
          for field in ws.header["Cookie"].split(/; /)
            (k, v) = field.split(/=/, 2)
            cookie[k] = CGI.unescape(v)
          end
          session_id = cookie[TSSWebServer::COOKIE_KEY]
          raise("session_id missing") if !session_id
          session = Session.get(session_id)
          auth_params = {
            :oauth_access_token => session[:access_token],
            :oauth_access_token_secret => session[:access_token_secret],
          }
          query = params["q"][0]
          thread = Thread.new() do
            begin
              res = search(query, auth_params)
              if res["results"]
                entries = res["results"].reverse()
                convert_entries(entries, :search)
                send(ws, {"entries" => entries})
                get_search_stream(query, auth_params) do |entry|
                  entries = [entry]
                  convert_entries(entries, :stream)
                  send(ws, {"entries" => entries})
                end
              else
                send(ws, {"error" => res["error"]})
              end
            rescue => ex
              print_backtrace(ex)
            end
            @logger.info("Streaming API connection closed: #{ws.object_id}")
            ws.close_socket() rescue nil
          end
          begin
            while ws.receive()
            end
          rescue => ex
          end
          thread.kill()
        else
          ws.handshake("404 Not Found")
        end
        @logger.info("Connection closed: #{ws.object_id}")
      end
    end
    
    def get_search_stream(query, auth_params, &block)
      buffer = ""
      url = URI.parse("http://stream.twitter.com/1/statuses/filter.json")
      Net::HTTP.new(url.host, url.port).start() do |http|
        req = Net::HTTP::Post.new(url.path)
        req.form_data = {'track' => query}
        authenticate(req, http, auth_params)
        http.request(req) do |res|
          if res.is_a?(Net::HTTPSuccess)
            res.read_body() do |s|
              buffer << s
              while buffer.gsub!(/\A(.*)\r\n/, "")
                json = $1
                if !json.empty?
                  entry = JSON.parse(json)
                  yield(entry)
                end
              end
            end
          else
            raise(res.to_s())
          end
        end
      end
    end
    
    def get_sample_stream(auth_params, &block)
      buffer = ""
      url = URI.parse("http://stream.twitter.com/1/statuses/sample.json")
      Net::HTTP.new(url.host, url.port).start() do |http|
        req = Net::HTTP::Get.new(url.path)
        authenticate(req, http, auth_params)
        http.request(req) do |res|
          if res.is_a?(Net::HTTPSuccess)
            res.read_body() do |s|
              buffer << s
              while buffer.gsub!(/\A(.*)\r\n/, "")
                json = $1
                if !json.empty?
                  entry = JSON.parse(json)
                  yield(entry)
                end
              end
            end
          else
            raise(res.to_s())
          end
        end
      end
    end
    
    def search(query, auth_params)
      # Authentication is optional for this method, but I do it here to let per-user
      # limit (instead of per-IP limit) applied to it.
      url = URI.parse(
        "http://search.twitter.com/search.json?q=%s&rpp=50&result_type=recent" % CGI.escape(query))
      Net::HTTP.new(url.host, url.port).start do |http|
        req = Net::HTTP::Post.new(url.path + "?" + url.query)
        authenticate(req, http, auth_params)
        res = http.request(req)
        return JSON.load(res.body)
      end
    end
    
    def authenticate(req, http, auth_params)
      if auth_params[:oauth_access_token] && auth_params[:oauth_access_token_secret]
        twitter_oauth = Twitter::OAuth.new(TWITTER_API_KEY, TWITTER_API_SECRET)
        twitter_oauth.authorize_from_access(
            auth_params[:oauth_access_token], auth_params[:oauth_access_token_secret])
        req.oauth!(http, twitter_oauth.signing_consumer, twitter_oauth.access_token)
      elsif auth_params[:user] && auth_params[:password]
        req.basic_auth(auth_params[:user], auth_params[:password])
      else
        raise("auth param missing")
      end
    end

    def convert_entries(entries, type)
      for entry in entries
        if type == :search
          entry["user"] = {
            "screen_name" => entry["from_user"],
            "profile_image_url" => entry["profile_image_url"],
          }
        end
        unescaped_text = CGI.unescapeHTML(entry["text"] || "")
        entry["unescaped_text"] = unescaped_text
        entry["text_html"] = auto_link(unescaped_text)
        entry["unescaped_source"] = CGI.unescapeHTML(entry["source"] || "")
        entry["delay_sec"] = (Time.now - Time.parse(entry["created_at"] || "")).to_i()
        if entry["retweeted_status"]
          convert_entries([entry["retweeted_status"]], type)
        end
      end
    end
    
    def send(ws, data)
      #if data["entries"]
      #  for entry in data["entries"]
      #    if entry["retweeted_status"]
      #      puts("rt: " + entry["retweeted_status"]["unescaped_text"])
      #    else
      #      puts(entry["user"]["screen_name"] + ": " + entry["unescaped_text"])
      #    end
      #    pp entry
      #  end
      #end
      begin
        ws.send(JSON.dump(data))
      rescue => ex
        print_backtrace(ex)
      end
    end
    
    # Streaming API output has "urls" information but it looks Search API output doesn't.
    # So I use my hand-made pattern matching.
    def auto_link(str)
      pos = 0
      result = ""
      uri_exp = URI.regexp(["http", "https", "ftp"])
      exp = /(^|\s|[^\x20-\x7f])((\#[a-zA-Z\d_]+)|(@[a-zA-Z\d_]+)|(#{uri_exp}))/
      str.gsub(exp) do
        m = Regexp.last_match
        result << CGI.escapeHTML(str[pos...m.begin(0)])
        prefix = $1
        if $3
          text = $3
          url = "/search?q=" + CGI.escape(text)
          target = "_self"
        elsif $4
          text = $4
          url = "http://twitter.com/%s" % text.gsub(/^@/, "")
          target = "_blank"
        elsif $5
          text = $5
          url = text
          target = "_blank"
        end
        result << '%s<a href="%s" target="%s">%s</a>' %
            [CGI.escapeHTML(prefix), CGI.escapeHTML(url), target, CGI.escapeHTML(text)]
        pos = m.end(0)
      end
      result << CGI.escapeHTML(str[pos..-1])
      return result
    end
    
    def print_backtrace(ex)
      @logger.error("%s: %s (%p)" % [ex.backtrace[0], ex.message, ex.class])
      for s in ex.backtrace[1..-1]
        @logger.error("        %s" % s)
      end
    end

end
