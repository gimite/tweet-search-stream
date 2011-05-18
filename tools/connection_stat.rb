#!/usr/bin/env ruby
# coding: utf-8

# Copyright: Hiroshi Ichikawa <http://gimite.net/en/>
# License: New BSD License

require "time"

conns = 0
time = nil
ARGF.each_line() do |line|
  if line =~ /^I, \[(\S+) \S+\]  INFO -- : \[websock\] connections=(.*)$/
    time = $1
    conns = eval($2)
    total = conns.inject(0){ |r, (a, b)| r + b }
    max = conns.max_by(){ |a, b| b }
    p [time, total, max]
  end
end
