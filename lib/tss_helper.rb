module TSSHelper
    
    LOGGER = Logger.new(STDERR)
    
    def never_die(&block)
      begin
        yield()
      rescue => ex
        print_backtrace(ex)
      end
    end
    
    def print_backtrace(ex)
      LOGGER.error("%s: %s (%p)" % [ex.backtrace[0], ex.message, ex.class])
      for s in ex.backtrace[1..-1]
        LOGGER.error("        %s" % s)
      end
    end

end
