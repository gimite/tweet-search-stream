#!/usr/bin/env ruby
# coding: utf-8

# Copyright: Hiroshi Ichikawa <http://gimite.net/en/>
# License: New BSD License

require "time"

conns = 0
time = nil
File.foreach("log/tss_server.output") do |line|
  if line =~ /^I, \[(\S+)/
    time = Time.parse($1)
  end
  if line =~ /Connection accepted: (-?\d+)/
    conns += 1
    p [time, conns]
  elsif line =~ /Connection closed: (-?\d+)/
    conns -= 1
    p [time, conns]
  elsif line =~ /WebSocket Server is running/
    conns = 0
    p [time, conns]
  end
end
