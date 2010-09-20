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
          :accepted_domains => [URI.parse(TSSConfig::BASE_URL).host],
          :port => TSSConfig::WEB_SOCKET_SERVER_PORT,
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
                convert_entries(entries)
                send(ws, {"entries" => entries})
                # For Streaming API, directly modifies JSON instead of parsing JSON and converting
                # back to JSON for efficiency.
                get_search_stream(query, auth_params) do |json|
                  json.slice!(json.length - 1, 1)  # Deletes last '}'
                  s = '{"entries": [%s,"now":%f}]}' % [json, Time.now.to_f()]
                  send_raw(ws, s)
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
      #url = URI.parse("http://192.168.1.7:12000/")
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
                  yield(json)
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
        twitter_oauth = Twitter::OAuth.new(TSSConfig::TWITTER_API_KEY, TSSConfig::TWITTER_API_SECRET)
        twitter_oauth.authorize_from_access(
            auth_params[:oauth_access_token], auth_params[:oauth_access_token_secret])
        req.oauth!(http, twitter_oauth.signing_consumer, twitter_oauth.access_token)
      elsif auth_params[:user] && auth_params[:password]
        req.basic_auth(auth_params[:user], auth_params[:password])
      else
        raise("auth param missing")
      end
    end

    # Converts entry in Search API to entry in Search Streaming API.
    def convert_entries(entries)
      for entry in entries
        entry["user"] = {
          "screen_name" => entry["from_user"],
          "profile_image_url" => entry["profile_image_url"],
        }
        entry["now"] = Time.now.to_f()
        if entry["retweeted_status"]
          convert_entries([entry["retweeted_status"]])
        end
      end
    end
    
    def send(ws, data)
      #print_data(data)
      send_raw(ws, JSON.dump(data))
    end
    
    def print_data(data)
      if data["entries"]
        for entry in data["entries"]
          if entry["retweeted_status"]
            puts("rt: " + entry["retweeted_status"]["text"])
          else
            puts(entry["user"]["screen_name"] + ": " + entry["text"])
          end
          #pp entry
        end
      end
    end
    
    def send_raw(ws, str)
      begin
        ws.send(str)
      rescue => ex
        print_backtrace(ex)
      end
    end
    
    def print_backtrace(ex)
      @logger.error("%s: %s (%p)" % [ex.backtrace[0], ex.message, ex.class])
      for s in ex.backtrace[1..-1]
        @logger.error("        %s" % s)
      end
    end

end
