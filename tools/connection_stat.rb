#!/usr/bin/env ruby
# coding: utf-8

# Copyright: Hiroshi Ichikawa <http://gimite.net/en/>
# License: New BSD License

conns = 0
File.foreach("log/tss_server.output") do |line|
  if line =~ /Connection accepted: (-?\d+)/
    conns += 1
    p conns
  elsif line =~ /Connection closed: (-?\d+)/
    conns -= 1
    p conns
  elsif line =~ /WebSocket Server is running/
    conns = 0
    p conns
  end
end
