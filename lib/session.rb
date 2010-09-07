#!/usr/bin/env ruby
# coding: utf-8

$KCODE = "u"

require "securerandom"


class Session
    
    STORE_PATH = "data/session.marshal"
    
    if File.exist?(STORE_PATH)
      @sessions = open(STORE_PATH, "rb"){ |f| Marshal.load(f) }
    else
      @sessions = {}
    end
    
    def self.get(id)
      return @sessions[id]
    end
    
    def self.save()
      open(STORE_PATH, "wb"){ |f| Marshal.dump(@sessions, f) }
    end
    
    def self.sessions
      return @sessions
    end
    
    def initialize()
      @id = SecureRandom.base64()
      @data = {}
      Session.sessions[@id] = self
    end
    
    attr_reader(:id)
    
    def [](key)
      return @data[key]
    end
    
    def []=(key, value)
      @data[key] = value
    end
    
    def clear()
      @data.clear()
    end
    
end
