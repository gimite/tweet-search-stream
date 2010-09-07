#!/usr/bin/env ruby
# coding: utf-8

$KCODE = "u"
$LOAD_PATH << "."
$LOAD_PATH << "./lib"

require "pp"

require "rubygems"
require "highline"

require "tss_web_server"
require "tss_web_socket_server"


Thread.abort_on_exception = true
#WebSocket.debug = true

case ARGV[0]
  
  when nil
    server = TSSWebSocketServer.new()
    Thread.new(){ server.run() }
    puts("WebSocket Server is running")
    TSSWebServer.run!(:port => 19016)
  
  when "test"
    if ARGV[1] == "oauth"
      auth_params = {
        :oauth_access_token => TEST_ACCESS_TOKEN,
        :oauth_access_token_secret => TEST_ACCESS_TOKEN_SECRET
      }
    else
      auth_params = {
        :user => "gimite",
        :password => HighLine.new().ask("Password: "){ |q| q.echo = false }
      }
    end
    server = TSSWebSocketServer.new()
    if ARGV[2] == "search"
      p server.search('#gimitetest', auth_params)
    else
      server.get_search_stream('#lessonlearned', auth_params) do |entry|
        puts("http://twitter.com/%s/status/%d" % [entry["user"]["screen_name"], entry["id"]])
        p [entry["created_at"], Time.now.gmtime]
        puts("rt") if entry["retweeted_status"]
        pp entry
        puts()
      end
    end
  
  when "dumpsession"
    p Session.sessions
  
  when "searchtest"
    search = Twitter::Search.new('#gimitetest')
    search.result_type("recent")
    search.to_a().reverse_each do |r|
      p r
    end
  
  when "rsstest"
    rss = RSS::Parser.parse(open("http://buzztter.com/ja/rss"){ |f| f.read() })
    for item in rss.items
      p item.title
    end
  
  when "autolinktest"
    puts(TSSWebSocketServer.new(true).auto_link(ARGV[1]))
  
  else
    raise("unknown action")

end
