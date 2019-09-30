# frozen_string_literal: true

require 'robustthread'
require 'yaml'

# Modukle of global variables and utility functions
module Globals
  APPLOG_LOGFILE = '/var/log/boiler_controller/boiler_controller.log'
  HEATING_LOGFILE = '/var/log/boiler_controller/boiler_heating.log'
  DAEMON_LOGFILE = '/var/log/boiler_controller/boiler_daemonlog.log'
  PIDFILE = '/var/run/boiler_controller/boiler_controller.pid'

  NO_SHUTDOWN = 'No Shutdown'
  NORMAL_SHUTDOWN = 'Normal Shutdown'
  FATAL_SHUTDOWN = 'Shutdown on Fatal Error'

  # The logger class
  class BoilerLogger < Logger
    attr_reader :app_logger, :heating_logger, :daemon_logger

    FATAL = 6
    INFO = 5
    ERROR = 4
    WARN = 3
    DEBUG = 2
    VERBOSE = 1
    TRACE = 0

    SEVS = %w[TRACE VERBOSE DEBUG WARN ERROR INFO FATAL].freeze
    def format_severity(severity)
      SEVS[severity] || 'ANY'
    end

    def fatal(progname = nil, &block)
      add(6, nil, progname, &block)
    end

    def info(progname = nil, &block)
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

  @app_logger = BoilerLogger.new(APPLOG_LOGFILE, 6, 1_000_000)

  @app_logger.formatter = proc { |severity, datetime, _progname, msg|
    if caller(4..4)[0].class == String
      "#{datetime.to_s.sub!(/^(.*) \+.*$/, '\1')} #{severity} "\
      "#{caller(4..4)[0].sub!(%r{^.*/(.*)$}, '\1')} :: #{msg}\n"
    else
      "#{datetime.to_s.sub!(/^(.*) \+.*$/, '\1')} #{severity} "\
      "#{caller(4..4)[0]} :: #{msg}\n"
    end
  }

  @heating_logger = Logger.new(HEATING_LOGFILE, 6, 1_000_000)
  @heating_logger.formatter = proc { |_severity, _datetime, _progname, msg|
    "#{msg}\n"
  }

  @daemon_logger = Logger.new(DAEMON_LOGFILE, 6, 1_000_000)
  @daemon_logger.formatter = proc { |severity, datetime, _progname, msg|
    if caller(4..4)[0].class == String
      "#{datetime.to_s.sub!(/^(.*) \+.*$/, '\1')} #{severity} "\
      "#{caller(4..4)[0].sub!(%r{^.*\/(.*)$}, '\1')} :: #{msg}\n"
    else
      "#{datetime.to_s.sub!(/^(.*) \+.*$/, '\1')} #{severity} "\
      "#{caller(4..4)[0]} :: #{msg}\n"
    end
  }

  # A class storing configuration items
  class Config
    # The mutex and the map for synchronizing read/write
    # the boiler configuration
    attr_reader :config_mutex, :logger
    attr_accessor :shutdown_reason, :pidpath
    def initialize(logger, config_path)
      @config_mutex = Mutex.new
      @config = {}
      @config_path = config_path
      @logger = logger

      @shutdown_reason = Globals::NO_SHUTDOWN
      @pidpath = ''.dup

      reload
    end

    def [](symbol)
      retval = nil
      @config_mutex.synchronize { retval = @config[symbol] }
      retval
    end

    def reload
      @config_mutex.synchronize { @config = YAML.load_file(@config_path) }
    rescue StandardError
      @logger.fatal('Cannot open config file: ' + @config_path + \
                        ' Shutting down.')
      @shutdown_reason = Globals::FATAL_SHUTDOWN
    end
  end

  # A Timer class for timing whole seconds
  class TimerSec
    attr_reader :name
    def initialize(timer_time, name)
      @name = name
      @timer_time = timer_time
      @start_ts = Time.now - @timer_time
    end

    def set_timer(timer_time)
      @timer_time = timer_time
    end

    def start
      @start_ts = Time.now if expired?
    end

    def sec_left
      expired? ? 0 : (Time.now - @start_ts).to_i
    end

    def expire
      @start_ts = Time.now - @timer_time
    end

    def expired?
      (Time.now - @start_ts).to_i >= @timer_time
    end

    def reset
      @start_ts = Time.now
    end
  end

  # A general timer
  class TimerGeneral < TimerSec
    def expired?
      (Time.now - @start_ts) >= @timer
    end
  end

  # A class that approximates a curve by returning the value of the linear
  # function defined by two neighbour points. Points' X values are expected
  # to be sorted and monotonously increasig.
  class Polycurve
    def initialize(pointlist, shift = 0)
      load(pointlist, shift)
    end

    def load(pointlist, shift = 0)
      if pointlist.size < 2
        raise 'Invalid array size - must be at least 2 it is: ' + \
              pointlist.size.to_s
      end

      @pointlist = Array.new(pointlist)
      @pointlist.each_index do |i|
        if @pointlist[i].size != 2
          raise 'Invalid array size at index ' + i.to_s + \
                ' must be 2 it is: ' + @pointlist[i].size.to_s
        end

        @pointlist[i][0] += shift
      end
    end

    def value(x_in, constrainted = true)
      float_value(x_in, constrainted).round
    end

    def float_value(x_in, constrainted = true)
      index = 0
      @pointlist.each_index do |n|
        index = n
        break if @pointlist[n][0] >= x_in
      end

      # pc = Polycurve.new([[1,10],[2,20],[5,500],[6,600]])

      # Check boundaries
      if constrainted
        return @pointlist.first[1].to_f if index.zero?
        return @pointlist.last[1].to_f if index == @pointlist.size - 1 &&
                                          @pointlist[index][0] < x_in
      elsif index.zero?
        index = 1
      end

      # point value on linear curve between the two neighbouring
      # or extrapolated points
      ((@pointlist[index - 1][1] - @pointlist[index][1])\
      / (@pointlist[index - 1][0] - @pointlist[index][0]).to_f\
      * (x_in - @pointlist[index - 1][0].to_f) + @pointlist[index - 1][1])
    end
    # End of class Polycurve
  end

  # A simple linear regression class
  class LinearRegression
    attr_accessor :slope, :offset
    def initialize(dx, dy = nil)
      @size = dx.size
      dy,dx = dx,axis() unless dy # make 2D if given 1D
      raise 'Arguments not same length!' unless @size == dy.size

      sxx = sxy = sx = sy = 0
      dx.zip(dy).each do |x, y|
        sxy += x * y
        sxx += x * x
        sx  += x
        sy  += y
      end
      @slope = (@size * sxy - sx * sy) / (@size * sxx - sx * sx)
      @offset = (sy - @slope * sx) / @size
    end

    def fit
      axis.map { |data| predict(data) }
    end

    def predict(x)
      @slope * x + @offset
    end

    def axis
      (0...@size).to_a
    end
  end
  # of Class LinearRegression

  # A PID controller class
  class PIDController
    def initialize(input_sensor, name,
                   k_p, k_i, k_d, setpoint,
                   outmin, outmax,
                   sampletime)
      @name = name

      @kp = k_p
      @ki = k_i
      @kd = k_d

      @input_sensor = input_sensor

      @setpoint = setpoint
      @sampletime = sampletime
      @outmin = outmin
      @outmax = outmax

      @active = false
      @stop_mutex = Mutex.new
      @modification_mutex = Mutex.new
    end

    def update_parameters(k_p, k_i, k_d,
                          setpoint,
                          outmin, outmax,
                          sampletime)
      @modification_mutex.synchronize do
        @kp = k_p
        @ki = k_i
        @kd = k_d
        @setpoint = setpoint
        @sampletime = sampletime
        @outmin = outmin
        @outmax = outmax
      end
    end

    def output
      raise 'PID not active - would return false values' unless @active

      @output
    end

    def start
      if @stop_mutex.locked?
        $app_logger.debug('Stopping PID controller operation active in '\
                          'PID controller: ' + @name)
        return
      end

      if @active
        $app_logger.debug('PID controller already active - returning')
        return
      else
        update_parameters
        @output = 0
        init
        @active = true
      end

      @pid_controller_thread = Thread.new do
        Thread.current[:name] = 'PID controller ' + @name
        until @stop_mutex.locked?
          @modification_mutex.synchronize { recalculate }
          sleep @sampletime unless @stop_mutex.locked?
        end
      end
    end

    def stop
      unless @active
        $app_logger.debug('PID not active - returning')
        return
      end

      if @stop_mutex.locked?
        $app_logger.debug('Stopping PID controller operation already '\
                          'active in PID controller: ' + @name)
        return
      end

      # Signal operation thread to exit
      @stop_mutex.lock

      # Wait for controller thread to exit
      @pid_controller_thread.join

      # Reset mutexes
      @stop_mutex.unlock
      @active = false
    end

    private

    def recalculate
      # Compute all the working error variables
      input = @input_sensor.temp

      error = @setpoint - input

      @i_term += @ki * error
      limit_output

      d_input = input - @last_input

      # Compute PID Output
      @output = @kp * error + @i_term - @kd * d_input
      limit_output

      # Remember lastInput
      @last_input = input
    end

    def limit_output
      if @output > @outmax
        @output = @outmax
      elsif @output < @outmin
        @output = @outmin
      end

      if @i_term > @outmax
        @i_term = @outmax
      elsif @i_term < @outmin
        @i_term = @outmin
      end
    end

    def init
      @last_input = @input_sensor.temp
      @i_term = @output
      if @i_term > @outmax
        @i_term = @outmax
      elsif @i_term < @outmin
        @i_term = @outmin
      end
    end
  end
  # of class PIDController
end
# End of module Globals
