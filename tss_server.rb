#!/usr/bin/env ruby
# coding: utf-8

# Copyright: Hiroshi Ichikawa <http://gimite.net/en/>
# License: New BSD License

$KCODE = "u" if RUBY_VERSION < "1.9.0"
$LOAD_PATH << "."
$LOAD_PATH << "./lib"
Thread.abort_on_exception = true

require "rubygems"
require "bundler/setup"

require "logger"
require "fileutils"

require "daemons"

require "tss_web_server"
require "tss_em_web_socket_server"


root_dir = File.dirname(File.expand_path(__FILE__))

opts = {
  :log_output => true,
  :dir_mode => :normal,
  :dir => "log",
  :monitor => true,
}
Daemons.run_proc("tss_server", opts) do
  FileUtils.cd(root_dir)
  TSSEMWebSocketServer.schedule()
  TSSWebServer.run!()
end
