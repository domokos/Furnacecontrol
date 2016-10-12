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
    if caller[3].class == String
      "#{datetime.to_s.sub!(/^(.*) \+.*$/,'\1')} #{severity} #{caller[3].sub!(/^.*\/(.*)$/,'\1')} #{msg}\n"
    else
      "#{datetime.to_s.sub!(/^(.*) \+.*$/,'\1')} #{severity} #{caller[3]} #{msg}\n"
    end
  }

  $heating_logger = Logger.new(HEATING_LOGFILE, 6, 1000000)
  $heating_logger.formatter = proc { |severity, datetime, progname, msg|
    "#{msg}\n"
  }

  $daemon_logger = Logger.new(DAEMON_LOGFILE, 6, 1000000)
  $daemon_logger.formatter = proc { |severity, datetime, progname, msg|
    if caller[4].class == String
      "#{datetime.to_s.sub!(/^(.*) \+.*$/,'\1')} #{severity} #{caller[3].sub!(/^.*\/(.*)$/,'\1')} #{msg}\n"
    else
      "#{datetime.to_s.sub!(/^(.*) \+.*$/,'\1')} #{severity} #{caller[3]} #{msg}\n"
    end
  }

  # The mutex and the map for synchronizing read/write the boiler configuration
  $config_mutex = Mutex.new
  $config = []

  def read_global_config
    begin
      $config_mutex.synchronize {$config = YAML.load_file(CONFIG_FILE_PATH)}
    rescue
      $app_logger.fatal("Cannot open config file: "+CONFIG_FILE_PATH+" Shutting down.")
      $shutdown_reason = Globals::FATAL_SHUTDOWN
    end
  end

  read_global_config

  # A Timer class for timing whole seconds
  class TimerSec

    attr_reader :name
    def initialize(timer_time,name)
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

    def sec_left()
      return expired? ? 0 : (Time.now - @start_ts).to_i
    end

    def expired?
      return (Time.now - @start_ts).to_i >= @timer_time
    end

    def reset
      @start_ts = Time.now
    end
  end

  # A general timer
  class TimerGeneral < TimerSec
    def expired?
      return (Time.now - @start_ts) >= @timer
    end
  end

  # A class that approximates a curve by returning the value of the linear function
  # defined by two neighbour points. Points' X values are expected to be sorted and monotonously increasig.
  class Polycurve
    def initialize(pointlist, shift = 0)
      load(pointlist, shift)
    end

    def load(pointlist, shift = 0)
      raise "Invalid array size - must be at least 2 it is: "+pointlist.size.to_s if pointlist.size < 2
      @pointlist = Array.new(pointlist)
      @pointlist.each_index do |i|
        raise "Invalid array size at index "+i.to_s+" must be 2 it is: "+@pointlist[i].size.to_s if @pointlist[i].size !=2
        @pointlist[i][0] += shift
      end
    end

    def value(x_in,constrainted=true)
      float_value(x_in,constrainted).round
    end

    def float_value (x_in,constrainted=true)
      index = 0
      @pointlist.each_index{ |n|
        index = n
        break if @pointlist[n][0] >= x_in
      }

      #pc = Polycurve.new([[1,10],[2,20],[5,500],[6,600]])

      # Check boundaries
      if constrainted
        return @pointlist.first[1].to_f if index == 0
        return @pointlist.last[1].to_f if index == @pointlist.size-1 and @pointlist[index][0] < x_in
      else
        index = 1 if index == 0
      end

      # Linear curve between the two neighbouring or extrapolated points
      return ((@pointlist[index-1][1]-@pointlist[index][1]) / (@pointlist[index-1][0]-@pointlist[index][0]).to_f \
      * (x_in-@pointlist[index-1][0].to_f) + @pointlist[index-1][1])
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

  class PIDController
    def initialize(input_sensor, name, kp, ki, kd, setpoint, outMin, outMax, sampleTime)
      @name = name

      @kp = kp
      @ki = ki
      @kd = kd

      @input_sensor = input_sensor

      @setpoint = setpoint
      @sampleTime = sampleTime
      @outMin = outMin
      @outMax = outMax

      @active = false
      @stop_mutex = Mutex.new
      @modification_mutex = Mutex.new
    end

    def update_parameters(kp,ki,kd,setpoint,outMin,outMax,sampleTime)
      @modification_mutex.synchronize do
        @kp = kp
        @ki = ki
        @kd = kd
        @setpoint = setpoint
        @sampleTime = sampleTime
        @outMin = outMin
        @outMax = outMax
      end
    end

    def output
      raise "PID not active - would return false values" unless @active
      return @output
    end

    def start
      if @stop_mutex.locked?
        $app_logger.debug("Stopping PID controller operation active in PID controller: "+@name)
        return
      end

      if @active
        $app_logger.debug("PID controller already active - returning")
        return
      else
        update_parameters
        @output = 0
        init
        @active = true
      end

      @pid_controller_thread = Thread.new do
        Thread.current[:name] = "PID controller "+@name
        while !@stop_mutex.locked?
          @modification_mutex.synchronize { recalculate }
          sleep @sampleTime unless @stop_mutex.locked?
        end
      end
    end

    def stop
      if !@active
        $app_logger.debug("PID not active - returning")
        return
      end

      if @stop_mutex.locked?
        $app_logger.debug("Stopping PID controller operation already active in PID controller: "+@name)
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

      @ITerm += @ki * error
      limit_output

      dInput = input - @lastInput

      # Compute PID Output
      @output = @kp * error + @ITerm- @kd * dInput
      limit_output

      # Remember lastInput
      @lastInput = input
    end

    def limit_output
      if @output > @outMax
        @output = @outMax
      elsif @output < @outMin
        @output = @outMin
      end

      if @ITerm > @outMax
        @ITerm = @outMax
      elsif @ITerm < @outMin
        @ITerm = @outMin
      end
    end

    def init
      @lastInput = @input_sensor.temp
      @ITerm = @output
      if @ITerm > @outMax
        @ITerm = @outMax
      elsif @ITerm < @outMin
        @ITerm = @outMin
      end
    end
  end # of class PIDController
  #End of module Globals
end