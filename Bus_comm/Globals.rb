require "robustthread"

module Globals

  APPLOG_LOGFILE = "/var/log/boiler_controller/boiler_controller.log"
  HEATING_LOGFILE = "/var/log/boiler_controller/boiler_heating.log"
  DAEMON_LOGFILE = "/var/log/boiler_controller/boiler_daemonlog.log"
  PIDFILE = "/var/run/boiler_controller/boiler_controller.pid"

  #Config file paths
  CONFIG_FILE_PATH = "/etc/boiler_controller/boiler_controller.yml"
  TEST_CONTROL_FILE_PATH = "/etc/boiler_controller/boiler_test_controls.yml"

  NO_SHUTDOWN = "No Shutdown"
  NORMAL_SHUTDOWN = "Normal Shutdown"
  FATAL_SHUTDOWN = "Shutdown on Fatal Error"
  class BoilerLogger < Logger

    INFO = 6
    FATAL = 5
    ERROR = 4
    WARN = 3
    DEBUG = 2
    VERBOSE = 1
    TRACE = 0

    SEVS = %w(TRACE VERBOSE DEBUG WARN ERROR FATAL INFO)
    def format_severity(severity)
      SEVS[severity] || 'ANY'
    end

    def info(progname = nil, &block)
      add(6, nil, progname, &block)
    end

    def fatal(progname = nil, &block)
      add(5, nil, progname, &block)
    end

    def error(progname = nil, &block)
      add(4, nil, progname, &block)
    end

    def warn(progname = nil, &block)
      add(3, nil, progname, &block)
    end

    def debug(progname = nil, &block)
      add(2, nil, progname, &block)
    end

    def verbose(progname = nil, &block)
      add(1, nil, progname, &block)
    end

    def trace(progname = nil, &block)
      add(0, nil, progname, &block)
    end

  end

  $app_logger = BoilerLogger.new(APPLOG_LOGFILE, 6 , 1000000)

  $app_logger.formatter = proc { |severity, datetime, progname, msg|
    if caller[4].class == String
      "#{datetime.to_s.sub!(/^(.*) \+.*$/,'\1')} #{severity} #{caller[4].sub!(/^.*\/(.*)$/,'\1')} #{msg}\n"
    else
      "#{datetime.to_s.sub!(/^(.*) \+.*$/,'\1')} #{severity} #{caller[4]} #{msg}\n"
    end
  }

  $heating_logger = Logger.new(HEATING_LOGFILE, 6, 1000000)
  $heating_logger.formatter = proc { |severity, datetime, progname, msg|
    "#{msg}\n"
  }

  $daemon_logger = Logger.new(DAEMON_LOGFILE, 6, 1000000)
  $daemon_logger.formatter = proc { |severity, datetime, progname, msg|
    if caller[4].class == String
      "#{datetime.to_s.sub!(/^(.*) \+.*$/,'\1')} #{severity} #{caller[4].sub!(/^.*\/(.*)$/,'\1')} #{msg}\n"
    else
      "#{datetime.to_s.sub!(/^(.*) \+.*$/,'\1')} #{severity} #{caller[4]} #{msg}\n"
    end
  }

  # A Timer class for timing whole seconds
  class TimerSec
    def initialize(sec_to_sleep,name)
      @name = name
      @sec_to_sleep = sec_to_sleep
      @timer_thread = nil
      @sec_left = 0
    end

    def start
      @sec_left = @sec_to_sleep
      @timer_thread = Thread.new do
        Thread.current["thread_name"] = @name
        while @sec_left > 0
          sleep(1)
          @sec_left = @sec_left - 1
        end
      end
    end

    def sec_left()
      return @sec_left
    end

    def expired?
      return @sec_left == 0
    end

    def reset
      stop
      start
    end

    def stop
      @timer_thread != nil and @timer_thread.kill
      @timer_thread = nil
      @sec_left=0
    end
  end

  # A general timer
  class TimerGeneral
    def initialize(amount_to_sleep,name)
      @name = name
      @amount_to_sleep = amount_to_sleep
      @timer_thread = nil
    end

    def start
      @timer_thread = Thread.new do
        Thread.current["thread_name"] = @name
        sleep @amount_to_sleep
      end
    end

    def expired?
      @timer_thread == nil or @timer_thread.stop?
    end

    def reset
      stop
      start
    end

    def stop
      @timer_thread != nil and @timer_thread.kill
      @timer_thread = nil
      @sec_left=0
    end
  end

  # A class that approximates a curve by returning the value of the linear function
  # defined by two neighbour points. Points' X values are expected to be sorted and monotonously increasig.
  class Polycurve
    def initialize(pointlist, shift = 0)
      @pointlist = Array.new(pointlist)
      @pointlist.each_index {|i| @pointlist[i][0] += shift }
    end

    def value (x_in)
      index = 0
      @pointlist.each_index{ |n|
        index = n
        break if @pointlist[n][0] >= x_in
      }

      # Check boundaries
      return @pointlist.first[1] if index == 0
      return @pointlist.last[1] if index == @pointlist.size-1

      # Linear curve between the two neighbour points
      return ((@pointlist[index-1][1]-@pointlist[index][1]) / (@pointlist[index-1][0]-@pointlist[index][0]).to_f * (x_in-@pointlist[index-1][0].to_f) + @pointlist[index-1][1]).round
    end

    # End of class Polycurve
  end

  class LinearRegression
    attr_accessor :slope, :offset
    def initialize dx, dy=nil
      @size = dx.size
      dy,dx = dx,axis() unless dy  # make 2D if given 1D
      raise "Arguments not same length!" unless @size == dy.size
      sxx = sxy = sx = sy = 0
      dx.zip(dy).each do |x,y|
        sxy += x*y
        sxx += x*x
        sx  += x
        sy  += y
      end
      @slope = ( @size * sxy - sx*sy ) / ( @size * sxx - sx * sx )
      @offset = (sy - @slope*sx) / @size
    end

    def fit
      return axis.map{|data| predict(data) }
    end

    def predict( x )
      y = @slope * x + @offset
    end

    def axis
      (0...@size).to_a
    end
  end # of Class LinearRegression

  class TempAnalyzer
    attr_reader :slope
    def initialize(buffersize=6)
      reset
      @buffersize = buffersize
    end

    def reset
      @temp_vector = []
      @timestamp_vector = []
      @starting_timestamp = Time.now.to_f
      @slope = nil
    end

    def size
      @timestamp_vector.size
    end

    def update(current_temp)
      now = Time.now.to_f

      if now-@starting_timestamp > 243
        @timestamp_vector.each_index {|x| @timestamp_vector[x] = @timestamp_vector[x]-(now-@starting_timestamp) }
        @starting_timestamp = now
      end

      @temp_vector.push(current_temp)
      @timestamp_vector.push(now-@starting_timestamp)

      if @temp_vector.length > @buffersize
        @temp_vector.shift
        @timestamp_vector.shift
      end

      return unless @temp_vector.length > 1

      lr=LinearRegression.new(@timestamp_vector,@temp_vector)

      @slope = lr.slope

    end
  end # of Class TempAnalyzer

  #End of module Globals
end