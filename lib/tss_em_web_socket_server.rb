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
require "moji"
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
        uri = URI.parse(ws.request["path"])
        params = CGI.parse(uri.query)
        if uri.path != "/" || params["q"].empty?
          ws.close_with_error("bad request")
          return
        end
        query_terms = parse_query(params["q"][0])
        search(query_terms.join(" OR ")) do |json|
          
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
          
          suggested_query = nil
          if query_terms.any?(){ |s| !(s =~ /\A\#[^ ,]+\z/) }
            error = "QUERY_NOT_HASH_TAGS"
            related_tags = extract_hash_tags(entries)
            suggested_query = related_tags.empty? ? nil : related_tags.join(" OR ")
          elsif query_terms.size > 4
            error = "TOO_MANY_TERMS"
          elsif query_terms.join(",").length > 60
            error = "QUERY_TOO_LONG"
          else
            error = nil
          end
          if error
            send(ws, {"error" => error, "suggested_query" => suggested_query})
            ws.close_connection_after_writing()
            next
          end
          
          if @stream_state == :connected && query_terms.all?(){ |s| @query_to_wsocks.has_key?(s) }
            # This should be after the check in if-statement above.
            register_web_socket(query_terms, ws)
            dump_connections()
          else
            register_web_socket(query_terms, ws)
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
      
      queries = @query_to_wsocks.keys
      api_query = queries.join(",")
      escaped_queries = {}
      for query in queries
        escaped_queries[query] = escape_for_json(query)
      end
      
      http = nil
      start_search_stream(api_query, {
        :on_init => proc() do |h|
          # It seems it's possible that on_close is called immediately before start_search_stream()
          # returns, so I need to assign to http here.
          @stream_http = http = h
          LOGGER.info("[stream %d] Connecting: api_query=%p" % [http.object_id, api_query])
          @stream_state = :connected
        end,
        :on_connect => proc() do
          if http.response_header.status == 200
            LOGGER.info("[stream %d] Connected" % http.object_id)
            @reconnect_wait_sec = DEFAULT_RECONNECT_WAIT_SEC
          end
        end,
        :on_entry => proc() do |json|
          # For efficiency, avoids parsing and redumping JSON.
          # Instead, uses regexp to extract Tweet text to match search query, and uses string
          # manipulation to add additional field "now".
          # There may be more than one "text" in different level and it's hard to find real one,
          # so joins values of all "text" field.
          text = json.scan(/"text":"(([^"\\]|\\.)*)"/).map(){ |a, b| a }.join(" ").downcase
          json.slice!(json.length - 1, 1)  # Deletes last '}'
          data = '{"entries": [%s,"now":%f}]}' % [json, Time.now.to_f()]
          wsocks = Set.new()
          for query in queries
            if text.index(escaped_queries[query]) && @query_to_wsocks[query]
              wsocks.merge(@query_to_wsocks[query])
            end
          end
          # Passing String with UTF-8 encoding causes error.
          # This is fixed in repository, so this force_encoding must be removed when I update
          # em-websocket to >0.3.1.
          data.force_encoding(Encoding::ASCII_8BIT)
          for wsock in wsocks
            wsock.send(data)
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
    
    def register_web_socket(query_terms, ws)
      for term in query_terms
        @query_to_wsocks[term] ||= []
        @query_to_wsocks[term].push(ws)
      end
      @wsock_to_last_access[ws] = Time.now
    end
    
    def unregister_web_socket(ws)
      found = false
      for query, wsocks in @query_to_wsocks
        if wsocks.delete(ws)
          found = true
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
      # Passing String with UTF-8 encoding causes error.
      # This is fixed in repository, so this force_encoding must be removed when I update
      # em-websocket to >0.3.1.
      ws.send(JSON.dump(data).force_encoding(Encoding::ASCII_8BIT))
    end
    
    def escape_for_json(str)
      return str.gsub(/[^\x20-\x7e]+/) do
        $&.unpack("U*").map(){ |i| "\\u%04x" % i }.join("")
      end
    end
    
    def parse_query(query)
      query = Moji.normalize_zen_han(query).strip()
      return query.split(/\s+OR\s+/).map(){ |s| s.downcase }
    end
    
    def extract_hash_tags(entries)
      tag_freqs = Hash.new(0)
      for entry in entries
        text = Moji.normalize_zen_han(CGI.unescapeHTML(entry["text"])).downcase
        for tag in text.scan(/\#[^\x00-\x2f\x3a-\x40\x5b-\x5e\x60\x7b-\x7f]+/).uniq()
          tag_freqs[tag] += 1
        end
      end
      return tag_freqs.sort_by(){ |t, f| -f }[0, 4].map(){ |t, f| t }
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
