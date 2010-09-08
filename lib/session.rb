#!/usr/bin/env ruby
# coding: utf-8

$KCODE = "u"

require "securerandom"


class Session
    
    STORE_PATH = "data/session.marshal"
    
    def self.get(id)
      session = @sessions[id]
      session.touch() if session
      return session
    end
    
    def self.start_auto_save()
      Thread.new() do
        while true
          sleep(30)
          save()
        end
      end
      at_exit(){ save() }
    end
    
    def self.save()
      for id, session in @sessions
        if session.last_access_at < Time.now - 3 * 30 * 24 * 3600
          puts("Session #{id} is expired")
          @sessions.delete(id)
        end
      end
      open(STORE_PATH, "wb"){ |f| Marshal.dump(@sessions, f) }
    end
    
    def self.sessions
      return @sessions
    end
    
    def initialize()
      @id = SecureRandom.base64()
      @data = {}
      @last_access_at = Time.now
      Session.sessions[@id] = self
    end
    
    attr_reader(:id, :last_access_at)
    
    def [](key)
      return @data[key]
    end
    
    def data=(data)
      @data = data
    end
    
    def clear()
      @data = {}
    end
    
    def touch()
      @last_access_at = Time.now
    end
    
    if File.exist?(STORE_PATH)
      @sessions = open(STORE_PATH, "rb"){ |f| Marshal.load(f) }
    else
      @sessions = {}
    end
    
end
