# coding: utf-8

# Copyright: Hiroshi Ichikawa <http://gimite.net/en/>
# License: New BSD License

$KCODE = "u" if RUBY_VERSION < "1.9.0"

require "securerandom"
require "pp"
require "cgi"
require "time"
require "enumerator"
require "logger"
require "uri"

require "rubygems"
require "json"
require "oauth"
require "oauth/client/em_http"
require "em-websocket"
require "em-http"
# Tried this but it didn't work with OAuth (Twitter returns 401) for unknown reason...
# require "twitter/json_stream"

require "tss_config"
require "session"
require "tss_web_server"


class TSSEMWebSocketServer
    
    def self.schedule()
      TSSEMWebSocketServer.new().schedule()
    end
    
    def initialize(logger = nil)
      @logger = logger || Logger.new(STDERR)
      @oauth_consumer = OAuth::Consumer.new(
        TSSConfig::TWITTER_API_KEY, TSSConfig::TWITTER_API_SECRET, :site => "http://twitter.com")
      @oauth_access_token = OAuth::AccessToken.new(
        @oauth_consumer, TSSConfig::TEST_ACCESS_TOKEN, TSSConfig::TEST_ACCESS_TOKEN_SECRET)
      @query_to_wsocks = {}
      @stream_http = nil
      @stream_state = :idle
    end
    
    def schedule()
      EventMachine.schedule() do
        port = TSSConfig::WEB_SOCKET_SERVER_PORT
        EventMachine::WebSocket.start(:host => "0.0.0.0", :port => port) do |ws|
          ws.onopen(){ on_web_socket_open(ws) }
          ws.onclose(){ on_web_socket_close(ws) }
          ws.onmessage(){ }
          ws.onerror(){ |r| on_web_socket_error(ws, r) }
        end
        @logger.info("WebSocket Server is running: port=%d" % port)
      end
    end
    
    def on_web_socket_open(ws)
      never_die() do
        
        @logger.info("%d: Connected" % ws.object_id)
        uri = URI.parse(ws.request["Path"])
        params = CGI.parse(uri.query)
        if uri.path != "/" || params["q"].empty?
          ws.close_with_error("bad request")
          return
        end
        query = params["q"][0].downcase
        search(query) do |json|
          
          res = json && JSON.load(json)
          if !res || !res["results"]
            message = (res && res["error"]) ? res["error"] : "Search API failed."
            send(ws, {"error" => message})
            ws.close_connection_after_writing()
            return
          end
          entries = res["results"].reverse()
          convert_entries(entries)
          send(ws, {"entries" => entries})
          
          if !(query =~ /\A\#[a-z0-9_]+\z/)
            send(ws, {"error" => "Auto update works only for hash tags."})
            ws.close_connection_after_writing()
            return
          end
          if @stream_state == :connected && @query_to_wsocks.has_key?(query)
            @query_to_wsocks[query].push(ws)
            dump_connections()
          else
            @query_to_wsocks[query] ||= []
            @query_to_wsocks[query].push(ws)
            reconnect_to_stream()
          end
          
        end
        
      end
    end
    
    def reconnect_to_stream(force = false)
      return if !force && @stream_state == :will_reconnect
      if @stream_state == :connected
        @stream_http.close_connection()
        @stream_http = nil
      end
      @query_to_wsocks.delete_if(){ |q, wss| wss.empty? }
      dump_connections()
      if @query_to_wsocks.empty?
        @stream_state = :idle
        return
      end
      query = @query_to_wsocks.keys.join(",")
      @stream_http = http = get_search_stream(query, {
        :on_entry => proc() do |json|
          if json =~ /"text":"(([^"\\]|\\.)*)"/
            text = $1.downcase
            json.slice!(json.length - 1, 1)  # Deletes last '}'
            data = '{"entries": [%s,"now":%f}]}' % [json, Time.now.to_f()]
            for query, wsocks in @query_to_wsocks
              if text.index(query)
                for wsock in wsocks
                  wsock.send(data)
                end
              end
            end
          end
        end,
        :on_close => proc() do
          @logger.info("%d: stream closed: status=%d body=%s" %
            [http.object_id, http.response_header.status, http.response])
          if http == @stream_http  # Otherwise it's disconnected for reconnection.
            @logger.info("reconnect in 10 sec")
            EventMachine.add_timer(10) do
              reconnect_to_stream(true)
            end
            @stream_state = :will_reconnect
          end
        end,
      })
      @logger.info("%d: reconnect to stream: query=%s" % [http.object_id, query])
      @stream_state = :connected
    end
    
    def dump_connections()
      @logger.info("connections: %p" % [@query_to_wsocks.map(){ |k, v| [k, v.size] }])
    end
    
    def on_web_socket_close(ws)
      never_die() do
        @logger.info("%d: Disconnected" % ws.object_id)
        unregister_web_socket(ws)
      end
    end
    
    def on_web_socket_error(ws, reason)
      never_die() do
        @logger.info("%d: WebSocket error: %p" % [ws.object_id, reason])
        unregister_web_socket(ws)
      end
    end
    
    def unregister_web_socket(ws)
      found = false
      for query, wsocks in @query_to_wsocks
        if wsocks.delete(ws)
          found = true
          break
        end
      end
      @logger.warn("%d: unregistered socket not found" % ws.object_id) if !found
      dump_connections()
    end
    
    def oauth_post_request(url, params, options = {})
      request = EventMachine::HttpRequest.new(url)
      base_options = {
        :body => params,
        :head => {"Content-Type" => "application/x-www-form-urlencoded"},
      }
      return request.post(base_options.merge(options)) do |client|
        @oauth_consumer.sign!(client, @oauth_access_token)
      end
    end
    
    def get_search_stream(query, params)
      http = oauth_post_request(
        "http://stream.twitter.com/1/statuses/filter.json",
        {"track" => query},
        {:timeout => 0})  # Disables timeout.
      buffer = ""
      http.stream do |chunk|
        never_die() do
          buffer << chunk
          while buffer.slice!(/\A(.*)\r\n/n)
            params[:on_entry].call($1)
          end
        end
      end
      http.callback() do |*args|
        never_die() do
          p [:callback, args]
          params[:on_close].call()
          #puts "Response: #{http.response} (Code: #{http.response_header.status})"
        end
      end
      http.errback() do |*args|
        never_die() do
          params[:on_close].call()
        end
      end
      return http
    end
    
    def search(query, &block)
      # Authentication is optional for this method, but I do it here to let per-user
      # limit (instead of per-IP limit) applied to it.
      http = oauth_post_request(
        "http://search.twitter.com/search.json",
        {"q" => query, "rpp" => 50, "result_type" => "recent"},
        :timeout => 30)
      http.callback() do
        never_die() do
          yield(http.response)
        end
      end
      http.errback() do
        never_die() do
          yield(nil)
        end
      end
    end
    
    def never_die(&block)
      begin
        yield()
      rescue => ex
        print_backtrace(ex)
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
      ws.send(JSON.dump(data))
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
    
    def print_backtrace(ex)
      @logger.error("%s: %s (%p)" % [ex.backtrace[0], ex.message, ex.class])
      for s in ex.backtrace[1..-1]
        @logger.error("        %s" % s)
      end
    end

end
