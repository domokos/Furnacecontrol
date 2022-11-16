# frozen_string_literal: true

require '/usr/local/lib/boiler_controller/buscomm'
require '/usr/local/lib/boiler_controller/globals'
require '/usr/local/lib/boiler_controller/bus_device'
require '/usr/local/lib/boiler_controller/buffer_sm'
require 'rubygems'

module BoilerBase
  # A low pass filter to filter out jitter from sensor data
  class Filter
    def initialize(size)
      @size = size
      @content = []
      @dirty = true
      @value = nil
      @filter_mutex = Mutex.new
    end

    def reset
      @filter_mutex.synchronize do
        @content = []
        @dirty = true
        @value = nil
      end
    end

    def depth
      @content.size
    end

    def input_sample(the_sample)
      @filter_mutex.synchronize do
        @content.push(the_sample)
        @content.shift if @content.size > @size
        @dirty = true
      end
    end

    def value
      @filter_mutex.synchronize do
        if @dirty
          return nil if @content.empty?

          sum = 0
          @content.each { |element| sum += element }
          @value = sum.to_f / @content.size
          @dirty = false
        end
      end
      @value
    end
  end
  # of class Filter

  # The Thermostat base class providing hysteresis behavior to a sensor
  class ThermostatBase
    attr_reader :state, :threshold
    attr_accessor :hysteresis

    def initialize(sensor, hysteresis, threshold, filtersize)
      @sensor = sensor
      @hysteresis = hysteresis
      @threshold = threshold
      @sample_filter = Filter.new(filtersize)
      @state = if @sensor.temp >= @threshold
                 :off
               else
                 :on
               end
    end

    def on?
      @state == :on
    end

    def off?
      @state == :off
    end

    def update
      @sample_filter.input_sample(@sensor.temp)
      determine_state
    end

    def test_update(next_sample)
      @sample_filter.input_sample(next_sample)
      determine_state
    end

    def threshold=(new_threshold)
      @threshold = new_threshold
      determine_state
    end

    def temp
      @sample_filter.value
    end

    # End of class definition Thermostat base
  end

  # Class of the Symmetric thermostat
  class SymmetricThermostat < ThermostatBase
    def determine_state
      if @state == :off
        @state = :on if @sample_filter.value < @threshold - @hysteresis
      elsif @sample_filter.value > @threshold + @hysteresis
        @state = :off
      end
    end
  end

  # Class of the asymmetric thermostat
  class ASymmetricThermostat < ThermostatBase
    attr_accessor :up_hysteresis, :down_hysteresis

    def initialize(sensor,
                   down_hysteresis, up_hysteresis,
                   threshold, filtersize)
      @sensor = sensor
      @up_hysteresis = up_hysteresis
      @down_hysteresis = down_hysteresis
      @threshold = threshold
      @sample_filter = Filter.new(filtersize)
      @state = if @sensor.temp >= @threshold
                 :off
               else
                 :on
               end
    end

    def determine_state
      if @state == :off
        @state = :on if @sample_filter.value < @threshold - @down_hysteresis
      elsif @sample_filter.value > @threshold + @up_hysteresis
        @state = :off
      end
    end

    def set_hysteresis(new_down_hysteresis,new_up_hysteresis)
      @down_hysteresis = new_down_hysteresis
      @up_hysteresis = new_up_hysteresis
    end
  end

  # The base class of PWM thermostats with common timing
  class PwmBase
    attr_accessor :config

    def initialize(config, is_hw_or_valve_proc,
                   timebase = 3600)
      @config = config
      @logger = config.logger.app_logger
      @timebase = timebase
      @is_hw_or_valve_proc = is_hw_or_valve_proc
      @thermostat_instances = []
      @base_mutex = Mutex.new
      start_pwm_thread
    end

    def register(thermostat_instance)
      @base_mutex.synchronize { @thermostat_instances << thermostat_instance }
    end

    def init_thread
      # Wait for all instances being initialized
      safety_loop_counter = 0
      loop do
        initialized = true
        @thermostat_instances.each do |th|
          initialized &= !th.target.nil?
          # @logger.debug(th.name + " initialized: #{!th.target.nil?}")
          # @logger.debug("Thermostats initialized: #{initialized}")
        end
        sleep 0.5
        safety_loop_counter += 1
        if (safety_loop_counter % 120).zero?
          @logger.error("Waited #{(safety_loop_counter / 120).round(2)}\
          seconds in vain for all PWM thermostats to receive a target.")
        end
        break if initialized
      end
    end

    def start_pwm_thread
      @pwm_thread = Thread.new do
        Thread.current[:name] = 'PWM thermostat'
        # Wait for the main thread to create all PWM thermostat objects
        # we may get some later but those will just skip one cycle
        sleep(10)
        init_thread
        # Loop forever
        loop do
          # Calculate the threshold value for each instance
          @thermostat_instances.each do |th|
            th.update_threshold(@timebase)
            @logger
              .debug("#{th.name} pulse width set to: "\
                      "#{(th.threshold / @timebase * 100).round(0)}%")
          end

          # Perform the cycle
          @sec_elapsed = 0
          while @sec_elapsed < @timebase
            any_thermostats_on = false
            @thermostat_instances.each do |th|
              if th.threshold > @sec_elapsed
                if th.off?
                  th.on
                  @logger.debug('Turning on ' + th.name)
                end
                any_thermostats_on = true
              elsif th.on? && (@sec_elapsed != @timebase)
                th.off
                @logger.debug('Turning off ' + th.name)
              end
            end

            sleep(1)
            # Time does not pass if HW or valve movement is active and any of
            # the PWM thermostats are to be on as in this case time is spent on
            # HW or valve movement rather than heating. This actually is only
            # good for the active thermostats as others being switched off
            # suffer an increased off time - no easy way around this...
            (@sec_elapsed += 1) unless\
             @is_hw_or_valve_proc.call && any_thermostats_on
          end
          @logger.debug('End of PWM thermostat cycle')
        end
      end
    end
  end

  # A Pulse Width Modulation (PWM) Thermostat class providing a PWM output
  # signal based on sensor value
  # The class' PWM behaviour takes into account the real operating time of
  # the heating by calling a reference function
  # passed to it as an argument. The reference function should return true
  # at times, when the PWM thermostat should consider the PWM to be active.
  class PwmThermostat
    def initialize(base, sensor,
                   filtersize, value_proc,
                   name)
      # Update the Class variables

      @config = base.config
      @logger = @config.logger.app_logger
      @sensor = sensor
      @sample_filter = Filter.new(filtersize)
      @value_proc = value_proc
      @name = name

      @modification_mutex = Mutex.new

      @state = :off
      @target = nil
      @cycle_threshold = 0
      @base = base

      update

      base.register(self)
    end

    def name
      @modification_mutex.synchronize { @name }
    end

    def state
      @modification_mutex.synchronize { @state }
    end

    def threshold
      @modification_mutex.synchronize { @cycle_threshold }
    end

    def update_threshold(timebase)
      @modification_mutex.synchronize do
        @cycle_threshold = timebase * @value_proc.call(@sample_filter, @target)
      end
    end

    def update
      @modification_mutex.synchronize { @sample_filter.input_sample(@sensor.temp) }
    end

    def test_update(next_sample)
      @modification_mutex.synchronize { @sample_filter.input_sample(next_sample)}
    end

    def temp
      @modification_mutex.synchronize { @sample_filter.value }
    end

    def on?
      @modification_mutex.synchronize { @state == :on }
    end

    def off?
      @modification_mutex.synchronize { @state == :off }
    end

    def target
      @modification_mutex.synchronize { @target }
    end

    def target=(target)
      @modification_mutex.synchronize { @target = target }
    end

    def value
      @modification_mutex.synchronize { @value_proc.call(@sample_filter, @target) }
    end

    def on
      @modification_mutex.synchronize { @state = :on }
    end

    def off
      @modification_mutex.synchronize { @state = :off }
    end
  end
  # End of class PwmThermostat

  # Class of the Mixer controller device
  class MixerControl
    def initialize(mix_sensor, cw_switch, ccw_switch,
                   config,
                   initial_target_temp = 34.0)
      # Initialize class variables
      @mix_sensor = mix_sensor
      @target_temp = initial_target_temp
      @cw_switch = cw_switch
      @ccw_switch = ccw_switch

      # Copy the configuration
      @config = config
      @logger = config.logger.app_logger

      # Create Filters
      @mix_filter = Filter.new(@config[:mixer_filter_size])
      @mix_filter.input_sample(25)

      @target_mutex = Mutex.new
      @control_mutex = Mutex.new
      @measurement_mutex = Mutex.new
      @measurement_thread_mutex = Mutex.new
      @stop_measurement_requested = Mutex.new
      @control_thread_mutex = Mutex.new
      @stop_control_requested = Mutex.new
      @paused = true
      @resuming = false

      @control_thread = nil
      @measurement_thread = nil

      # Create the log rate limiter
      @mixer_log_rate_limiter = \
        Globals::TimerSec.new(@config[:mixer_limited_log_period],\
                              'Mixer controller log timer')
    end

    def init
      # Prefill sample buffer to get rid of false values
      @config[:mixer_filter_size].times do
        @mix_filter.input_sample(@mix_sensor.temp)
      end
      @integrated_cw_movement_time = 0
      @integrated_ccw_movement_time = 0
      @int_err_sum = 0
    end

    def temp
      @measurement_mutex.synchronize { @mix_filter.value }
    end

    def target_temp
      @target_temp
    end

    def target_temp=(new_target_temp)
      @target_mutex.synchronize { @target_temp = new_target_temp }
    end

    def start_control
      # Only start control thread if not yet started
      return unless @control_thread_mutex.try_lock

      @logger.debug('Mixer controller starting control')

      # Clear control thread stop sugnaling mutex
      @stop_control_requested.unlock if @stop_control_requested.locked?

      # Start control thread
      @control_thread = Thread.new do
        Thread.current[:name] = 'Mixer controller'
        # Acquire lock for controlling switches
        @control_mutex.synchronize do
          # Initialize mixer variables
          init
          start_measurement_thread
          @logger.trace('Mixer controller do_control_thread before '\
          'starting control loop')

          # Control until stop is requested
          until @stop_control_requested.locked?
            # Pause as long as pause is requested
            if @paused
              sleep 1
            else
              # Do the actual control
              do_control_thread

              # Delay between control actions
              sleep @config[:mixer_control_loop_delay] unless\
              @stop_control_requested.locked? || @paused
            end
          end
          # Stop the measurement thread before exiting
          stop_measurement_thread
        end
        # of control mutex synchronize
      end
    end

    def stop_control
      # Return if we do not have a control thread
      if !@control_thread_mutex.locked? || @control_thread.nil?
        @logger.debug(\
          'Mixer controller not running in stop control - returning')
        return
      end

      # Signal the control thread to exit
      @stop_control_requested.lock
      # Wait for the control thread to exit
      @control_thread.join
      @logger.debug('Mixer controller control_thread joined')

      # Allow the next call to start control to create a new control thread
      @control_thread_mutex.unlock
      @logger.debug('Mixer controller control_thread_mutex unlocked')
    end

    def pause
      if !@control_thread_mutex.locked? || @control_thread.nil?
        @logger.debug('Mixer controller not running in pause - returning')
        return
      end

      if @paused
        @logger.trace(\
          'Mixer controller - controller already paused - ignoring')
      else
        @logger.debug('Mixer controller - pausing control')
        # Signal controller to pause
        @paused = true
      end
    end

    def resumecheck
      if !@control_thread_mutex.locked? || @control_thread.nil?
        @logger.debug('Mixer controller not running')
        return false
      end

      unless @paused
        @logger.trace('Mixer controller - controller not paused')
        return false
      end

      if @resuming
        @logger.trace('Mixer controller - resuming active')
        return false
      end
      true
    end

    def resume
      return unless resumecheck

      @resuming = true
      Thread.new do
        Thread.current[:name] = 'Mixer resume thread'
        # Initialize mixer variables
        init

        @logger.debug('Mixer controller - resuming control')

        # Signal controller to resume
        @paused = false
        @resuming = false
      end
    end

    def start_measurement_thread
      @logger.debug('Mixer controller - measurement thread start requested')
      return unless @measurement_thread_mutex.try_lock

      # Unlock the measurement thread exis signal
      @stop_measurement_requested.unlock if @stop_measurement_requested.locked?

      # Create a temperature measurement thread
      @measurement_thread = Thread.new do
        Thread.current[:name] = 'Mixer measurement'
        @logger.debug('Mixer controller - measurement thread starting')
        until @stop_measurement_requested.locked?
          @measurement_mutex.synchronize\
            { @mix_filter.input_sample(@mix_sensor.temp) }
          sleep @config[:mixer_sampling_delay] unless\
            @stop_measurement_requested.locked?
        end
        @logger.debug('Mixer controller - measurement thread exiting')
      end
    end

    def stop_measurement_thread
      # Return if we do not have a measurement thread
      return if !@measurement_thread_mutex.locked? || @measurement_thread.nil?

      # Signal the measurement thread to exit
      @stop_measurement_requested.lock

      # Wait for the measurement thread to exit
      @logger.debug(\
        'Mixer controller - waiting for measurement thread to exit'
      )
      @measurement_thread.join
      @logger.debug('Mixer controller - measurement thread joined')

      # Allow a next call to start_measurement thread to create
      # a new measurement thread
      @measurement_thread_mutex.unlock
      @logger.debug('Mixer controller - measurement_thread_mutex unlocked')
    end

    def log(value, error)
      # Copy the config for updates
      @logger.debug("Mixer forward temp: #{value.round(2)}")
      @logger.debug("Mixer controller error: #{error.round(2)}")
      @mixer_log_rate_limiter.timer = @config[:mixer_limited_log_period]
      @mixer_log_rate_limiter.reset
    end

    # The actual control thread
    def do_control_thread
      # Init local variables
      target = 0
      value = 0

      # Read target temp thread safely
      @target_mutex.synchronize { target = @target_temp }
      @measurement_mutex.synchronize { value = @mix_filter.value }

      error = target - value
      adjustment_time = calculate_adjustment_time(error)

      log(value, error) if @mixer_log_rate_limiter.expired?

      # Adjust mixing motor if it is needed
      return if adjustment_time.abs.zero?

      @logger.trace('Mixer controller target: '\
        "#{target.round(2)}")
      @logger.trace("Mixer controller value: #{value.round(2)}")
      @logger.trace('Mixer controller adjustment time: '\
        "#{adjustment_time.round(2)}")
      @logger.trace(\
        'Mixer controller int. cw time: '\
        "#{@integrated_cw_movement_time.round(2)}"
      )
      @logger.trace(\
        'Mixer controller int. ccw time: '\
        "#{@integrated_ccw_movement_time.round(2)}"
      )

      # Move CCW
      if adjustment_time.positive? && \
         @integrated_ccw_movement_time < \
         @config[:mixer_unidirectional_movement_time_limit]
        @logger.trace('Mixer controller adjusting ccw')
        @ccw_switch.pulse_block((adjustment_time * 10).to_i)

        # Keep track of movement time for limiting movement
        @integrated_ccw_movement_time += adjustment_time

        # Adjust available movement time for the other direction
        @integrated_cw_movement_time -= adjustment_time
        @integrated_cw_movement_time = 0 if @integrated_cw_movement_time.negative?

        # Move CW
      elsif adjustment_time.negative? && \
            @integrated_cw_movement_time < \
            @config[:mixer_unidirectional_movement_time_limit]
        adjustment_time = -adjustment_time
        @logger.trace('Mixer controller adjusting cw')
        @cw_switch.pulse_block((adjustment_time * 10).to_i)

        # Keep track of movement time for limiting movement
        @integrated_cw_movement_time += adjustment_time

        # Adjust available movement time for the other direction
        @integrated_ccw_movement_time -= adjustment_time
        @integrated_ccw_movement_time = 0 if @integrated_ccw_movement_time < 0
      else
        @logger.trace\
          ("Mixer controller not moving. Adj:#{adjustment_time.round(2)}"\
          " CW: #{@integrated_cw_movement_time} CCW: " + \
          @integrated_ccw_movement_time.to_s)
      end
    end

    # Calculate mixer motor actuation time based on error
    # This implements a simple P type controller with limited boundaries
    def calculate_adjustment_time(error)
      # Integrate the error if above the integrate threshold
      @int_err_sum += @config[:mixer_motor_ki_parameter] * error \
      if error.abs > @config[:mixer_motor_integrate_error_limit]

      if @int_err_sum.abs > @config[:mixer_motor_ival_limit]
        @int_err_sum = if @int_err_sum.positive?
                         @config[:mixer_motor_ival_limit]
                       else
                         -@config[:mixer_motor_ival_limit]
                       end
      end

      # Calculate the controller output
      retval = @config[:mixer_motor_kp_parameter] * error + @int_err_sum

      @logger.trace(\
        'Adjustments Pval: '\
        "#{(@config[:mixer_motor_kp_parameter] * error).round(2)} "\
        "Ival: #{@int_err_sum.round(2)}"
      )
      return 0 if retval.abs < @config[:min_mixer_motor_movement_time]

      if retval.abs > @config[:max_mixer_motor_movement_time]
        if retval.positive?
          @logger.trace("Calculated value: #{retval.round(2)} "\
            "returning: #{@config[:max_mixer_motor_movement_time]}")
          return @config[:max_mixer_motor_movement_time]
        else
          @logger.trace("Calculated value: #{retval.round(2)} "\
            "returning: -#{@config[:max_mixer_motor_movement_time]}")
          return -@config[:max_mixer_motor_movement_time]
        end
      end
      @logger.trace("Returning: #{retval.round(2)}")
      retval
    end
  end
  # of class MixerControl
end
# of module BoilerBase
