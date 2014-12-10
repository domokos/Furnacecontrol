#!/usr/bin/ruby

#	The class of the states
class State
	def initialize(name,description)
		@name = name
		@description = description
	end
	def set_activate(procblock)
		@procblock = procblock
	end
	def activate
		if @procblock.nil?
			print "Error: No activation action set for state ",@name,"\n"
			return nil
		else
		 	@procblock.call
		 	return self
		end
	end

	attr_accessor :description
	attr_accessor :name
end

# A Timer class
class Timer
	def initialize(sec_to_sleep,name)
		@sec_to_sleep = sec_to_sleep
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
		Thread.exit()
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

# A low pass filter to filter out jitter from sensor data
class Filter
	def initialize(size)
		@size = size
		@content = []
		@dirty = true
		@value = nil
	end

	def reset
		@content = []
		@dirty = true
		@value = nil
	end

	def input_sample(the_sample)
		@content.push(the_sample)
		@content.size > @size and @content.shift
		@dirty = true
		return value
	end

	def value
		if @dirty
			@content.size == 0 and return nil
			sum = 0
			@content.each do
			 	|element|
				sum += element
			end
			@value = sum.to_f / @content.size
			@dirty = false
		end
		return @value.to_f
	end
end

# The Thermostat base class providing some histeresis behavior to a sensor 
class Thermostat_base
	def initialize(sensor,histeresis,threshold,filtersize)
		@sensor = sensor
		@histeresis = histeresis
		@threshold = threshold
		@sample_filter = Filter.new(filtersize)
		if sensor.temp >= @threshold
			@state = "off"
		else
			@state = "on"
		end
	end

	def update
		@sample_filter.input_sample(@sensor.temp)
		determine_state
	end 

	def test_update(next_sample)
		@sample_filter.input_sample(next_sample)
		determine_state
	end 

	def set_threshold(new_threshold)
		@threshold = new_threshold
		determine_state
	end

	def set_histeresis(new_histeresis)
		@histeresis = new_histeresis
	end

	def state
		return @state
	end

	def temp
		return @sample_filter.value
	end

	def threshold
		return @threshold
	end
end

class Symmetric_thermostat < Thermostat_base
	def determine_state
		if @state == "off"
			@state = "on" if @sample_filter.value < @threshold - @histeresis
		else
			@state = "off" if @sample_filter.value > @threshold + @histeresis 
		end
	end
end

class Asymmetric_thermostat < Thermostat_base
	def initialize(sensor,down_histeresis,up_histeresis,threshold,filtersize)
		@sensor = sensor
		@up_histeresis = up_histeresis
		@down_histeresis = down_histeresis
		@threshold = threshold
		@sample_filter = Filter.new(filtersize)
		if sensor.temp >= @threshold
			@state = "off"
		else
			@state = "on"
		end
	end

	def determine_state
		if @state == "off"
			@state = "on" if @sample_filter.value < @threshold - @down_histeresis 
		else
			@state = "off" if @sample_filter.value > @threshold + @up_histeresis
		end
	end
	
	def set_histeresis(new_down_histeresis,new_up_histeresis)
		@down_histeresis = new_down_histeresis
		@up_histeresis = new_up_histeresis
	end

end

# A Pulse Width Modulation (PWM) Thermostat class providing a PWM output signal 
# based on sensor value
# The class' PWM behaviour takes into account the real operating time of the heating by calling a reference function
# passed to it as the last argument. The reference function should return true at times, when the PWM thermostat
# should consider the PWM to be active.
class PwmThermostat
  attr_accessor :cycle_threshold, :state

	def initialize(sensor,filtersize,value_proc,is_HW_or_valve,timebase=3600)
# Update the Class variables
	  @@timebase = timebase
		@@is_HW_or_valve = is_HW_or_valve

		@sensor = sensor
    @sample_filter = Filter.new(filtersize)
		@value_proc = value_proc

		@state = "off"
		@target = nil
		@cycle_threshold = 0

		@@thermostat_instances = [] unless defined?(@@thermostat_instances)
    @@thermostat_instances << self
    
    
	  self.class.start_pwm_thread unless defined?(@@pwm_thread)
	end

	def self.start_pwm_thread
    @@newly_initialized_thermostat_present = false
	  @@pwm_thread = Thread.new do
	    #Wait for the main thread to create all objects we need
	    sleep(10)
      while true

        @@newly_initialized_thermostat_present = false             
			  # Calculate the threshold value for each instance 
        @@thermostat_instances.each do |th|
			      th.cycle_threshold = @@timebase * th.value
			  end

			  # Perform the cycle
			  @@sec_elapsed = 0
			  while @@sec_elapsed < @@timebase
          any_thermostats_on = false
          @@thermostat_instances.each do |th|
            if th.cycle_threshold > @@sec_elapsed
              th.state = "on"
              any_thermostats_on = true
            else
              th.state = "off"
            end
          end

          sleep(1)
			    # Time does not pass if HW or valve movement is active and any of the PWM thermostats 
          # are to be on as in this case furnace effort is spent on HW or valve movement rather
          # than on heating. This actually is only good for the active thermostats as others
          # being switched off suffer an increased off time - no easy way around this...
          (@@sec_elapsed = @@sec_elapsed + 1) unless (@@is_HW_or_valve.call and any_thermostats_on)

          
			    #Relax for 15 secs then recalculate if any of the thermostats declared new initialization
          if @@newly_initialized_thermostat_present
            @@thermostat_instances.each do |th|
              th.state = "off"
            end
            sleep(15)
            break
          end
			  end
			  
		    $do_tests and puts "------- End of PWM cycle ------------"
		end
	 end
	end

	def PwmThermostat.finalize
	  @@pwm_thread.kill
	end

	def update
    # Request thread cycle restart if newly initialized
	  @@newly_initialized_thermostat_present = (@@newly_initialized_thermostat_present or (@sample_filter.value == nil and @target != nil))
	  @sample_filter.input_sample(@sensor.temp)
	end 

	def test_update(next_sample)
		@sample_filter.input_sample(next_sample)
	end 

	def temp
		return @sample_filter.value
	end

  def set_target (target)
    # Request thread cycle restart if newly initialized
    @@newly_initialized_thermostat_present = (@@newly_initialized_thermostat_present or (@target == nil and @sample_filter.value != nil))
    @target = target
  end
	
	def value
		if @sample_filter.value != nil and @target != nil 
		  return @value_proc.call(@sample_filter,@target)
		else
		  return 0
		end
	end
end


# This class controls the furnace by taking a kW value as an input and converting it into a
# PWM output. The output's value is to be decoded as follows:
# 0 - furnace off
# 1 - burner 1 on
# 2 - both burners on
class Furnace_PWM
	def initialize(lower_period,upper_period)
		@PWMvalue = 0
		@output = 0
# Period below an output of 1, as an output state change requires ignition,
# a larger period is required
		@lower_period = lower_period 
# Period above an output of 1, as an output state change requires no ignition,
# a relatively short period can be allowed
		@upper_period = upper_period
		@cycle_length = 0
		@current_cycle = 0
		@pwm_thread_started = false
	end

	def reset
		@PWMvalue = 0
		@output = 0
		@cycle_length = 0
		@current_cycle = 0
		if @pwm_thread_started 
		      @pwm_thread.kill
		      @pwm_thread_started = false
		end
	end

# Decoding the arbitrary input value into physically plausible PWM values
	def set_value(kWvalue)
		if kWvalue >= 29.3
			@PWMvalue = 2
		elsif kWvalue >= 20.5
			@PWMvalue = (kWvalue-20.5) / 8.8 + 1
		elsif kWvalue > 0
			@PWMvalue = kWvalue / 20.5
		else
			@PWMvalue = 0
		end
		!@pwm_thread_started and start_pwm_thread
	end

	def cycle_length
		return @cycle_length
	end

	def pWMvalue
		return @PWMvalue
	end

	def output
		return @output
	end

	def determine_rates
		if @PWMvalue == 0
			@on_time = 0
			@off_time = 3
			@on_value = 0
			@off_value = 0
		elsif @PWMvalue > 0 && @PWMvalue < 1
			@on_time = @lower_period
			@off_time = @lower_period*(1-@PWMvalue)/@PWMvalue

			@off_time = 3 if @off_time < 3 
			@off_time = 12 if @off_time > 12

			@on_value = 1
			@off_value = 0
		elsif @PWMvalue >= 1 && @PWMvalue < 1.5
			@on_time = @upper_period
			if(@PWMvalue !=1)
				@off_time = @upper_period*(2-@PWMvalue)/(@PWMvalue-1)
			else 
				@off_time = 12
			end

			@off_time = 12 if @off_time > 12 
			@off_time = 3 if @off_time < 3

			@on_value = 2
			@off_value = 1
		elsif @PWMvalue >= 1.5 && @PWMvalue < 2
			@off_time = @upper_period
			@on_time = @upper_period*(@PWMvalue-1)/(2-@PWMvalue)

			 @on_time = 12 if @on_time > 12

			@on_value = 2
			@off_value = 1
		elsif @PWMvalue == 2
			@on_time = @upper_period
			@off_time = 0
			@on_value = 2
			@off_value = 2
		end
		@on_time = @on_time.round
		@off_time = @off_time.round
		@cycle_length =@on_time+@off_time
	end

	def recalculate_off_values
	print "Recalc\n"
#		if @PWMvalue == 0
#		    @off_time = 1
#		    @off_value = 0
#		elsif @PWMvalue > 0 && @PWMvalue < 1
#		  if @on_value == 1
#		    @off_time = @on_time/@PWMvalue
#		    @off_time < 3  and @off_time = 3
#		    @off_time > 10 and @off_time = 10
#		    @off_value = 0
#		  else
#
#		  end
#
#		elsif @PWMvalue >= 1 && @PWMvalue < 1.5
#
#		elsif @PWMvalue >= 1.5 && @PWMvalue < 2
#		elsif @PWMvalue == 2
#
#		end
	end

	def start_pwm_thread
		@pwm_thread_started = true
		@pwm_thread = Thread.new do
			while true
			    determine_rates
			    @sec_left = @on_time
			    while @sec_left > 0
				    @output = @on_value
				    sleep(1)
				    @sec_left = @sec_left - 1
			    end
# Todo - a recalculation of off_time at this point using the past on_time as an 
# input will improve output accuracy.
#			    recalculate_off_values
			    @sec_left = @off_time
			    while @sec_left > 0
				    @output = @off_value
				    sleep(1)
				    @sec_left = @sec_left - 1
			    end
			end
			Thread.exit # Paranoidity
		end
	end
	
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
end

class Furnace_analyzer
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
    
    $debuglevel >1 and print "Analyzer LR slope: ",@slope,"\n"
    $debuglevel >1 and print "Analyzer timestamp_vector: [",@timestamp_vector.join(','),"]\n"
    $debuglevel >1 and print "Analyzer temp_vector: [",@temp_vector.join(','),"]\n" 

  end
end


class PD_controller
	def initialize(p_gain,d_gain)
		@p_gain = p_gain
		@d_gain = d_gain
		@starting_timestamp = Time.now.to_f
		@timestamp_vector = []
		@error_vector = []
	end

	def reset
		@starting_timestamp = Time.now.to_f
		@timestamp_vector = []
		@error_vector = []
	end


	def output(current_error)
		now = Time.now.to_f

		if now-@starting_timestamp > 200
		  @timestamp_vector.each_index {|x| @timestamp_vector[x] = @timestamp_vector[x]-(now-@starting_timestamp) }
		  @starting_timestamp = now
		end

		@error_vector.push(current_error)
		@timestamp_vector.push(now-@starting_timestamp)

		if @error_vector.length > 6
		      @error_vector.shift
		      @timestamp_vector.shift
		end

		return 0 unless @error_vector.length > 1

		lr=LinearRegression.new(@timestamp_vector,@error_vector)
		$debuglevel >1 and print "PD LR slope: ",lr.slope,"\n"
		$debuglevel >1 and print "PD timestamp_vector: [",@timestamp_vector.join(','),"]\n"
		$debuglevel >1 and print "PD error_vector: [",@error_vector.join(','),"]\n"
		return @d_gain*lr.slope+@p_gain*current_error
	end
end