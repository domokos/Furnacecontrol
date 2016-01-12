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

  # The mutex and the map for synchronizing read/write the boiler configuration
  $config_mutex = Mutex.new
  $config = []

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
      raise "Invalid array size - must be at least 2 it is: "+pointlist.size.to_s if pointlist.size < 2
      @pointlist = Array.new(pointlist)
      @pointlist.each_index do |i|
        raise "Invalid array size at index "+i.to_s+" must be 2 it is: "+@pointlist[i].size.to_s if @pointlist[i].size !=2 
        @pointlist[i][0] += shift
      end
    end

    def value(x_in,constarinted=true)
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
      @slope = 0
      @stable = false
    end

    def average(vector=@temp_vector)
      return 0 if vector.size == 0
      sum = 0.0
      vector.each {|x| sum += x.to_f}
      return sum / vector.size
    end

    def sigma(vector=@temp_vector)
      return 0 if vector.size == 0
      avg = average(vector)
      nominator = 0.0
      vector.each {|x| nominator += (x-avg)*(x-avg) }
      return Math.sqrt(nominator/vector.size)
    end

    def stable?
      return @stable
    end

    def compute_stability
      return if @temp_vector.size != @buffersize

      first_slopes = []
      sign_changes = []

      # Calculate slope based on first and second neighbors
      @temp_vector.each_index do
        |i|
        first_slopes.push((@temp_vector[i+1] - @temp_vector[i])/(@timestamp_vector[i+1]-@timestamp_vector[i]))  if i < @buffersize-1
        (sign_changes.push(i) if (first_slopes[i-1]<0 and first_slopes[i]>0) or (first_slopes[i-1]>0 and first_slopes[i]<0)) if (i<@buffersize-1 and i>0)
      end

      # Stable if the derivate vectors do not change direction/sign significantly
      # this is tested by

      sign = first_slopes[0] < 0 ? -1 : 1
      max_negative_deviation = 0
      max_positive_deviation = 0
      inhomogenity = false
      positives = []
      negatives = []

      first_slopes.each do
        |element|
        case
        # OK
        when (element<0 and sign<0)
          max_negative_deviation = element if element < max_negative_deviation
          negatives.push(element)
          # Inhomogenity
        when (element<0 and sign>=0)
          inhomogenity = true
          max_negative_deviation = element if element < max_negative_deviation
          negatives.push(element)
          # OK
        when (element>0 and sign<0)
          max_negative_deviation = element if element < max_negative_deviation
          positives.push(element)
          # Inhomogenity
        when (element<0 and sign>=0)
          inhomogenity = true
          max_negative_deviation = element if element < max_negative_deviation
          positives.push(element)
        end
      end

      # If there is no inhomogenity then the vector is stable
      return true if !inhomogenity

      return true if sigma(@temp_vector[@temp_vector.size/4*3,@temp_vector.size-1]) < 0.06

      return false
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
      @stable = compute_stability
    end
  end # of Class TempAnalyzer

  #End of module Globals
end