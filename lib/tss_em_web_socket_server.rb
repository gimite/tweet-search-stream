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
require "tss_web_server"
require "tss_helper"


class TSSEMWebSocketServer
    
    include(TSSHelper)
    
    DEFAULT_RECONNECT_WAIT_SEC = 10
    # Must be somewhat longer than PING_INTERVAL_MSEC in view/search.erb.
    PING_TIMEOUT_SEC = 6 * 60
    
    def self.schedule()
      TSSEMWebSocketServer.new().schedule()
    end
    
    def initialize()
      @oauth_consumer = OAuth::Consumer.new(
        TSSConfig::TWITTER_API_KEY,
        TSSConfig::TWITTER_API_SECRET,
        :site => "http://twitter.com")
      @oauth_access_token = OAuth::AccessToken.new(
        @oauth_consumer,
        TSSConfig::TWITTER_API_ACCESS_TOKEN,
        TSSConfig::TWITTER_API_ACCESS_TOKEN_SECRET)
      @query_to_wsocks = {}
      @wsock_to_last_access = {}
      @stream_http = nil
      @stream_state = :idle
      @reconnect_wait_sec = DEFAULT_RECONNECT_WAIT_SEC
      @recent_reconnections = [Time.at(0)] * 3
    end
    
    def schedule()
      EventMachine.schedule() do
        port = TSSConfig::WEB_SOCKET_SERVER_PORT
        EventMachine::WebSocket.start(:host => "0.0.0.0", :port => port) do |ws|
          ws.onopen(){ on_web_socket_open(ws) }
          ws.onclose(){ on_web_socket_close(ws) }
          ws.onmessage(){ |m| on_web_socket_message(ws, m) }
          ws.onerror(){ |r| on_web_socket_error(ws, r) }
        end
        EventMachine.add_periodic_timer(PING_TIMEOUT_SEC){ on_gc_timer() }
        LOGGER.info("WebSocket Server is running: port=%d" % port)
      end
    end
    
    def on_web_socket_open(ws)
      never_die() do
        
        LOGGER.info("[websock %d] Connected" % ws.object_id)
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
            next
          end
          entries = res["results"].reverse()
          convert_entries(entries)
          send(ws, {"entries" => entries})
          
          if !(query =~ /\A\#[a-z0-9_]+\z/)
            send(ws, {"error" => "Auto update works only for hash tags."})
            ws.close_connection_after_writing()
            next
          end
          if @stream_state == :connected && @query_to_wsocks.has_key?(query)
            register_web_socket(query, ws)
            dump_connections()
          else
            register_web_socket(query, ws)
            reconnect_to_stream()
          end
          
        end
        
      end
    end
    
    def on_web_socket_message(ws, message)
      never_die() do
        @wsock_to_last_access[ws] = Time.now
      end
    end
    
    def on_web_socket_close(ws)
      never_die() do
        LOGGER.info("[websock %d] Disconnected" % ws.object_id)
        unregister_web_socket(ws)
      end
    end
    
    def on_web_socket_error(ws, reason)
      never_die() do
        LOGGER.info("[websock %d] WebSocket error: %p" % [ws.object_id, reason])
        unregister_web_socket(ws)
      end
    end
    
    def on_gc_timer()
      never_die() do
        now = Time.now
        for ws, la in @wsock_to_last_access.select(){ |ws, la| la < now - PING_TIMEOUT_SEC }
          LOGGER.info("[websock %d] WebSocket timeout" % ws.object_id)
          ws.close_connection()
          unregister_web_socket(ws)
        end
      end
    end
    
    def reconnect_to_stream(by_timer = false)
      
      if !by_timer && @stream_state == :will_reconnect
        LOGGER.info("[stream] Waiting for reconnection, reconnection ignored")
        return
      end
      
      # If this is 4th reconnection in 60 sec, wait for 60 sec,
      # to avoid Twitter API error.
      if @recent_reconnections[0] >= Time.now - 60
        reconnect_later(60)
        return
      end
      @recent_reconnections.push(Time.now)
      @recent_reconnections.shift()
      
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
      
      http = nil
      start_search_stream(query, {
        :on_init => proc() do |h|
          # It seems it's possible that on_close is called immediately before start_search_stream()
          # returns, so I need to assign to http here.
          @stream_http = http = h
          LOGGER.info("[stream %d] Connecting: query=%p" % [http.object_id, query])
          @stream_state = :connected
        end,
        :on_connect => proc() do
          if http.response_header.status == 200
            LOGGER.info("[stream %d] Connected" % http.object_id)
            @reconnect_wait_sec = DEFAULT_RECONNECT_WAIT_SEC
          end
        end,
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
          if http == @stream_http
            LOGGER.info("[stream %d] Closed unexpectedly: status=%p body=%p" %
              [http.object_id, http.response_header.status, http.response])
            reconnect_later(@reconnect_wait_sec)
            @reconnect_wait_sec = [@reconnect_wait_sec * 2, 240].min
          else
            # Intentionally disconnected to reconnect with a new query.
            LOGGER.info("[stream %d] Closed intentionally: status=%p body=%p" %
              [http.object_id, http.response_header.status, http.response])
          end
        end,
      })
      
    end
    
    def reconnect_later(wait_sec)
      LOGGER.info("[stream] Reconnect in %d sec" % wait_sec)
      EventMachine.add_timer(wait_sec) do
        reconnect_to_stream(true)
      end
      @stream_state = :will_reconnect
    end
    
    def register_web_socket(query, ws)
      @query_to_wsocks[query] ||= []
      @query_to_wsocks[query].push(ws)
      @wsock_to_last_access[ws] = Time.now
    end
    
    def unregister_web_socket(ws)
      found = false
      for query, wsocks in @query_to_wsocks
        if wsocks.delete(ws)
          found = true
          break
        end
      end
      LOGGER.info("[websock %d] Unregistered socket not found" % ws.object_id) if !found
      @wsock_to_last_access.delete(ws)
      dump_connections()
    end
    
    def start_search_stream(query, params)
      http = oauth_post_request(
        "http://stream.twitter.com/1/statuses/filter.json",
        {"track" => query},
        {:timeout => 0})  # Disables timeout.
      params[:on_init].call(http)
      buffer = ""
      connected = false
      http.stream do |chunk|
        never_die() do
          if !connected
            params[:on_connect].call()
            connected = true
          end
          buffer << chunk
          while buffer.slice!(/\A(.*)\r\n/n)
            params[:on_entry].call($1)
          end
        end
      end
      http.callback() do
        never_die() do
          params[:on_close].call()
        end
      end
      http.errback() do
        never_die() do
          params[:on_close].call()
        end
      end
    end
    
    def search(query, &block)
      # Authentication is optional for this method, but I do it here to let per-user
      # limit (instead of per-IP limit) applied to it.
      http = oauth_post_request(
        "http://search.twitter.com/search.json",
        {"q" => query, "rpp" => 50, "result_type" => "recent"},
        :timeout => 30)
      LOGGER.info("[search %d] Fetching: query=%p" % [http.object_id, query])
      http.callback() do
        never_die() do
          LOGGER.info(
            "[search %d] Fetched: status=%p" % [http.object_id, http.response_header.status])
          yield(http.response_header.status == 200 ? http.response : nil)
        end
      end
      http.errback() do
        never_die() do
          LOGGER.info("[search %d] Failed" % http.object_id)
          yield(nil)
        end
      end
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
    
    def dump_connections()
      LOGGER.info("[websock] connections=%p" % [@query_to_wsocks.map(){ |k, v| [k, v.size] }])
    end
    
end
