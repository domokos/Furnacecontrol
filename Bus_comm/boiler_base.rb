require "/usr/local/lib/boiler_controller/Buscomm"
require "/usr/local/lib/boiler_controller/Globals"
require "/usr/local/lib/boiler_controller/bus_device"
require "rubygems"
require "robustthread"

module BoilerBase
  # Define the modes of the heating
  class Mode
    def initialize(name,description)
      @name = name
      @description = description
    end
    attr_accessor :description
  end

  # The class of the heating states
  class State
    attr_accessor :description, :name
    def initialize(name,description)
      @name = name
      @description = description
    end

    def set_activate(procblock)
      @procblock = procblock
    end

    def activate
      if @procblock.nil?
        $logger.error("No activation action set for state "+@name)
        return nil
      else
        @procblock.call
        return self
      end
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
      @content.shift if @content.size > @size
      @dirty = true
      return value
    end

    def value
      if @dirty
        return nil if @content.empty?

        # Filter out min-max values to further minimize jitter
        # in case of big enough filters
        if @content.size > 7
          content_tmp = Array.new(@content.sort)
          content_tmp.pop if content_tmp[content_tmp.size-1] != content_tmp[content_tmp.size-2]
          content_tmp.shift if content_tmp[0] != content_tmp[1]
        else
          content_tmp = @content
        end

        sum = 0
        content_tmp.each do
          |element|
          sum += element
        end
        @value = sum.to_f / content_tmp.size
        @dirty = false
      end
      return @value
    end
  end

  # The Thermostat base class providing histeresis behavior to a sensor
  class Thermostat_base
    attr_reader :state, :threshold
    attr_accessor :histeresis
    def initialize(sensor,histeresis,threshold,filtersize)
      @sensor = sensor
      @histeresis = histeresis
      @threshold = threshold
      @sample_filter = Filter.new(filtersize)
      if @sensor.temp >= @threshold
        @state = :off
      else
        @state = :on
      end
    end

    def is_on?
      @state == :on
    end

    def is_off?
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

    def set_threshold(new_threshold)
      @threshold = new_threshold
      determine_state
    end

    def temp
      @sample_filter.value
    end

    # End of class definition Thermostat base
  end

  class Symmetric_thermostat < Thermostat_base
    def determine_state
      if @state == :off
        @state = :on if @sample_filter.value < @threshold - @histeresis
      else
        @state = :off if @sample_filter.value > @threshold + @histeresis
      end
    end
  end

  class Asymmetric_thermostat < Thermostat_base

    attr_accessor :up_histeresis, :down_histeresis
    def initialize(sensor,down_histeresis,up_histeresis,threshold,filtersize)
      @sensor = sensor
      @up_histeresis = up_histeresis
      @down_histeresis = down_histeresis
      @threshold = threshold
      @sample_filter = Filter.new(filtersize)
      if @sensor.temp >= @threshold
        @state = :off
      else
        @state = :on
      end
    end

    def determine_state
      if @state == :off
        @state = :on if @sample_filter.value < @threshold - @down_histeresis
      else
        @state = :off if @sample_filter.value > @threshold + @up_histeresis
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
  # passed to it as an argument. The reference function should return true at times, when the PWM thermostat
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

      @state = :off
      @target = nil
      @cycle_threshold = 0

      @@thermostat_instances = [] if defined?(@@thermostat_instances) == nil
      @@thermostat_instances << self

      start_pwm_thread if defined?(@@pwm_thread) == nil
    end

    def start_pwm_thread
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
                th.state = :on
                any_thermostats_on = true
              else
                th.state = :off
              end
            end

            sleep(1)
            # Time does not pass if HW or valve movement is active and any of the PWM thermostats
            # are to be on as in this case time is spent on HW or valve movement rather
            # than heating. This actually is only good for the active thermostats as others
            # being switched off suffer an increased off time - no easy way around this...
            (@@sec_elapsed = @@sec_elapsed + 1) unless (@@is_HW_or_valve.call and any_thermostats_on)

            #Relax for 15 secs then recalculate if any of the thermostats declared new initialization
            if @@newly_initialized_thermostat_present
              @@thermostat_instances.each do |th|
                th.state = :off
              end
              sleep(15)
              break
            end
          end

          $app_logger.debug("End of PWM thermostat cycle")
        end
      end
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
      @sample_filter.value
    end

    def is_on?
      @state == :on
    end

    def is_off?
      @state == :off
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
    #End of class PwmThermostat
  end

  class Mixer_control

    FILTER_SAMPLE_SIZE = 3
    SAMPLING_DELAY = 2.1
    ERROR_THRESHOLD = 1.1
    MIXER_CONTROL_LOOP_DELAY = 6
    MOTOR_TIME_PARAMETER = 1
    UNIDIRECTIONAL_MOVEMENT_TIME_LIMIT = 60
    MOVEMENT_TIME_HYSTERESIS = 5
    def initialize(mix_sensor,cw_switch,ccw_switch,initial_target_temp=34.0)

      # Initialize class variables
      @mix_sensor = mix_sensor
      @target_temp = initial_target_temp
      @cw_switch = cw_switch
      @ccw_switch = ccw_switch

      # Create Filters
      @mix_filter = Filter.new(FILTER_SAMPLE_SIZE)

      @target_mutex = Mutex.new
      @control_mutex = Mutex.new
      @measurement_mutex = Mutex.new
      @measurement_thread_mutex = Mutex.new
      @stop_measurement_requested = Mutex.new
      @control_thread_mutex = Mutex.new
      @stop_control_requested = Mutex.new

      @control_thread = nil
      @measurement_thread = nil

      @integrated_cw_movement_time = 0
      @integrated_ccw_movement_time = 0

      # Reset the device
      reset
    end

    def set_target_temp(new_target_temp)
      @target_mutex.synchronize {@target_temp = new_target_temp}
    end

    # Move it to the middle
    def reset
      Thread.new do
        if @control_mutex.try_lock
          sleep 2
          ccw_switch.pulse(36)
          sleep 2
          cw_switch.pulse(15)
          sleep 2
          @control_mutex.unlock
        end
      end
    end

    def start_control(delay=0)
      # Only start control thread if not yet started
      return unless @control_thread_mutex.try_lock

      # Clear control thread stop sugnaling mutex
      @stop_control_requested.unlock if @stop_control_requested.locked?
      # Start control thread
      @control_thread = Thread.new do
        # Acquire lock for controlling switches
        @control_mutex.synchronize do
          # Delay starting the controller process if requested
          sleep delay

          # Prefill sample buffer to get rid of false values
          FILTER_SAMPLE_SIZE.times {@mix_filter.input_sample(@mix_sensor.temp)}

          # Do the actual control, which will return ending the thread if done
          do_control_thread

          # Clear the control thread
          @control_thread = nil
        end
      end
    end

    def stop_control
      # Return if we do not have a control thread
      return if !@control_thread_mutex.locked? or @control_thread == nil

      # Signal the control thread to exit
      @stop_control_requested.lock
      # Wait for the control thread to exit
      @control_thread.join

      # Allow the next call to start control to create a new control thread
      @control_thread_mutex.unlock
    end

    def start_measurement_thread
      return unless @measurement_thread_mutex.try_lock

      # Unlock the measurement thread exis signal
      @stop_measurement_requested.unlock if @stop_measurement_requested.locked?

      #Create a temperature measurement thread
      @measurement_thread = Thread.new do
        while !@stop_measurement_requested.locked? do
          @measurement_mutex.synchronize {@mix_filter.input_sample(@mix_sensor.temp)}
          sleep SAMPLING_DELAY unless @stop_measurement_requested.locked?
        end
        $app_logger.debug("Mixer controller measurement thread exiting")
      end
    end

    def stop_measurement_thread
      # Return if we do not have a measurement thread
      return if !@measurement_thread_mutex.locked? or @measurement_thread == nil

      # Signal the measurement thread to exit
      @stop_measurement_requested.lock

      # Wait for the measurement thread to exit
      $app_logger.debug("Mixer controller waiting for measurement thread to exit")
      @measurement_thread.join

      # Allow a next call to start_measurement thread to create
      # a new measurement thread
      @measurement_thread_mutex.unlock
    end

    # The actual control thread
    def do_control_thread

      start_measurement_thread

      # Control until if stop is requested
      while !@stop_control_requested.locked? do

        # Minimum delay between motor actuations
        sleep MIXER_CONTROL_LOOP_DELAY

        # Read target temp thread safely
        @target_mutex.synchronize {target = @target_temp}
        @measurement_mutex.synchronize {error = target - @mix_filter}

        # Adjust mixing motor if error is out of bounds
        if error.abs > ERROR_THRESHOLD

          adjustment_time = calculate_adjustment_time(error.abs)

          # Move CCW
          if error > 0 and @integrated_CCW_movement_time < UNIDIRECTIONAL_MOVEMENT_TIME_LIMIT
            ccw_switch.pulse(adjustment_time)

            # Keep track of movement time for limiting movement
            @integrated_CCW_movement_time += adjustment_time

            # Adjust available movement time for the other direction
            @integrated_CW_movement_time = MOVEMENT_TIME_LIMIT - @integrated_CCW_movement_time - MOVEMENT_TIME_HYSTERESIS
            @integrated_CW_movement_time = 0 if @integrated_CW_movement_time < 0

            # Move CW
          elsif @integrated_CW_movement_time < UNIDIRECTIONAL_MOVEMENT_TIME_LIMIT
            cw_switch.pulse(adjustment_time)

            # Keep track of movement time for limiting movement
            @integrated_CW_movement_time += adjustment_time

            # Adjust available movement time for the other direction
            @integrated_CCW_movement_time = MOVEMENT_TIME_LIMIT - @integrated_CW_movement_time - MOVEMENT_TIME_HYSTERESIS
            @integrated_CCW_movement_time = 0 if @integrated_CCW_movement_time < 0
          end

        end

        # Stop the measurement thread before exiting
        stop_measurement_thread
      end

      @integrated_cw_movement_time = 0
      @integrated_ccw_movement_time = 0

    end

    # Calculate mixer motor actuation time based on error
    # This implements a simple P type controller with limited boundaries
    def calculate_adjustment_time(error)
      retval = MOTOR_TIME_PARAMETER * error
      return 1 if retval < 1
      return 10 if retval > 10
      return retval
    end

    #End of class MixerControl
  end

  class BufferHeat
    # Initialize the buffer taking its sensors and control valves
    def initialize(forward_sensor, upper_sensor, lower_sensor, return_sensor,
      hw_thermostat,
      forward_valve, return_valve,
      heater_relay, hydr_shift_pump, hw_pump,
      hw_wiper, heat_wiper)

      # Buffer Sensors
      @forward_sensor = forward_sensor
      @upper_sensor =  upper_sensor
      @lower_sensor = lower_sensor
      @return_sensor = return_sensor

      # HW_thermostat for filtered value
      @hw_thermostat = hw_thermostat

      # Valves
      @forward_valve = forward_valve
      @return_valve = return_valve

      # Pump, heat relay
      @heater_relay = heater_relay
      @hydr_shift_pump = hydr_shift_pump
      @hw_pump = hw_pump

      # Temp wipers
      @hw_wiper = hw_wiper
      @heat_wiper = heat_wiper

      # The control thread
      @control_thread = nil

      # This one ensures that there is only one control thread running
      @control_mutex = Mutex.new

      # Copy the configuration
      @config = $config.dup

      # This one signals the control thread to exit
      @stop_control = Mutex.new

      # This one is used to ensure atomicity of mode setting
      @modesetting_mutex = Mutex.new

      @feed_log_rate_limiter = 1
      @do_limited_rate_logging = true
      @control_log_rate_limiter = 1
      @do_limited_rate_control_logging = true

      # Create the state change relaxation timer
      @relax_timer = Globals::TimerSec.new(@config[:buffer_heater_state_change_relaxation_time],"Buffer heater state change relaxation timer")

      # Set the initial state
      @mode = @prev_mode = :off
      @control_thread = nil
      @relay_state = nil
      set_relays(:direct_boiler)
      @prev_relay_state_in_prev_heating_mode = :direct_boiler
      @heat_in_buffer = {:temp=>@upper_sensor.temp,:percentage=>((@upper_sensor.temp - @config[:buffer_base_temp])*100)/(@lower_sensor.temp - @config[:buffer_base_temp])}
      @target_temp = 7.0
    end

    # Update classes upon config_change
    def update_config_items
      @relax_timer.set_sleep_time(@config[:buffer_heater_state_change_relaxation_time])
    end

    # Set the operation mode of the buffer. This can take the below values as a parameter:
    #
    # :heat - The system is configured for heating. Heat is provided by the boiler or by the buffer.
    #         The logic actively decides what to do and how the valves/heating relays
    #         need to be configured
    #
    # :off - The system is configured for being turned off. The remaining heat from the boiler - if any - is transferred to the buffer.
    #
    # :HW - The system is configured for HW - Boiler relays are switched off  - this now does not take the solar option into account.

    def set_mode(new_mode)
      # Check validity of the parameter
      raise "Invalid mode parameter '"+new_mode.to_s+"' passed to set_mode(mode)" unless [:heat,:off,:HW].include? new_mode

      # Take action only if the mode is changing
      return if @mode == new_mode

      $app_logger.debug("Heater set_mode. Got new mode: "+new_mode.to_s)

      # Synchronize mode setting to the potentially running control thread
      @modesetting_mutex.synchronize do

        # Start and stop control thread according to the new mode
        new_mode == :off ? stop_control_thread : start_control_thread

        # Maintain a single level mode history and set the mode change flag
        @prev_mode = @mode
        @mode = new_mode
        @mode_changed = true

      end # of modesetting mutex sync
    end #of set_mode

    # Set the required forward water temperature
    def set_target(new_target_temp)
      #      @target_changed = (new_target_temp == @target_temp)
      @target_temp = new_target_temp
    end

    # Configure the relays for a certain purpose
    def set_relays(config)
      # Check validity of the parameter
      raise "Invalid relay config parameter '"+config.to_s+"' passed to set_relays(config)" unless
      [:direct_boiler,:buffer_passthrough,:feed_from_buffer].include? config

      $app_logger.debug("Relay state is: "+@relay_state.to_s)

      return if @relay_state == config

      moved = false

      case config
      when :direct_boiler
        $app_logger.debug("Setting relays to ':direct_bolier'")
        moved |= @forward_valve.state != :off
        @forward_valve.off
        moved |= @return_valve.state != :off
        @return_valve.off
        @relay_state = :direct_boiler
      when :buffer_passthrough
        $app_logger.debug("Setting relays to ':buffer_passthrough'")
        moved |= @forward_valve.state != :off
        @forward_valve.off
        moved |= @return_valve.state != :on
        @return_valve.on
        @relay_state = :buffer_passthrough
      when :feed_from_buffer
        $app_logger.debug("Setting relays to ':feed_from_buffer'")
        moved |= @forward_valve.state != :on
        @forward_valve.on
        moved |= @return_valve.state != :off
        @return_valve.off
        @relay_state = :feed_from_buffer
      end

      if moved
        $app_logger.debug("Waiting for relays to move into new position")

        # Wait until valve movement is complete
        sleep @config[:three_way_movement_time]
        return :delayed
      else
        $app_logger.debug("Relays not moved - not waiting")
        return :immediate
      end
    end

    private

    #
    # Evaluate heating conditions and
    # set feed strategy
    # This routine only sets relays and heat switches no pumps
    # circulation is expected to be stable when called
    #
    def set_heating_feed

      @heat_in_buffer = {:temp=>@upper_sensor.temp,:percentage=>((@upper_sensor.temp - @config[:buffer_base_temp])*100)/(@lower_sensor.temp - @config[:buffer_base_temp])}

      if @feed_log_rate_limiter > @config[:buffer_limited_log_period]
        @feed_log_rate_limiter = 1
        @do_limited_rate_logging = true
      else
        @feed_log_rate_limiter += 1
      end

      forward_temp = @forward_sensor.temp
      delta_t = @forward_sensor.temp - @return_sensor.temp
      boiler_on = delta_t < @config[:boiler_on_detector_delta_t_threshold]

      $app_logger.trace("--------------------------------")
      $app_logger.trace("Relax timer active: "+@relax_timer.sec_left.to_s) if !@relax_timer.expired?
      $app_logger.trace("Relay state: "+@relay_state.to_s)

      # Evaluate Direct Boiler state
      if @relay_state == :direct_boiler
        $app_logger.trace("Forward temp: "+forward_temp.to_s)
        $app_logger.trace("Target temp: "+@target_temp.to_s)
        $app_logger.trace("Threshold forward_above_target: "+@config[:forward_above_target].to_s)
        $app_logger.trace("Delta_t: "+delta_t.to_s)

        # Direct Boiler - State change condition evaluation
        if forward_temp > @target_temp + @config[:forward_above_target] and @relax_timer.expired?

          # Too much heat with direct heat - let's either feed from buffer or fill the buffer
          # based on how much heat is stored in the buffer
          $app_logger.debug("Boiler overheating state will change from direct boiler")
          $app_logger.debug("Heat in buffer: "+@heat_in_buffer[:temp].to_s+" Percentage: "+@heat_in_buffer[:percentage].to_s)

          if @heat_in_buffer[:temp] > @target_temp + @config[:init_buffer_reqd_temp_reserve] and @heat_in_buffer[:percentage] > @config[:init_buffer_reqd_fill_reserve]
            $app_logger.debug("Decision: Buffer contains enough heat - feed from buffer")
            if @heater_relay.state != :off
              $app_logger.debug("Turning off heater relay")
              @heater_relay.off
            end
            @heat_wiper.set_water_temp(7.0)

            $app_logger.debug("Waiting for boiler to stop before cutting it off from circulation")
            sleep @config[:circulation_maintenance_delay]
            set_relays(:feed_from_buffer)
          else
            $app_logger.debug("Decision: Buffer contains not much heat - fill buffer in passthrough mode")
            set_relays(:buffer_passthrough)
            # If feed heat into buffer raise the boiler temperature to be able to move heat out of the buffer later
            @heat_wiper.set_water_temp(@target_temp + @config[:buffer_passthrough_overshoot])
          end
          @relax_timer.reset

          # Direct Boiler - State maintenance operations
          # Just set the required water temperature
        else
          if @do_limited_rate_logging
            $app_logger.debug("Direct boiler. Target: "+@target_temp.to_s)
            $app_logger.debug("Forward temp: "+forward_temp.to_s)
            $app_logger.debug("Delta_t: "+delta_t.to_s)
            @do_limited_rate_logging = false
          end
          @heat_wiper.set_water_temp(@target_temp)
          if @heater_relay.state != :on
            $app_logger.debug("Turning on heater relay")
            @heater_relay.on
          end
        end

        # Evaluate Buffer Passthrough state
      elsif @relay_state == :buffer_passthrough
        $app_logger.trace("Forward temp: "+forward_temp.to_s)
        $app_logger.trace("Reqd./effective target temps: "+@target_temp.to_s+"/"+@heat_wiper.get_target.to_s)
        $app_logger.trace("buffer_passthrough_fwd_temp_limit: "+@config[:buffer_passthrough_fwd_temp_limit].to_s)
        $app_logger.trace("Delta_t: "+delta_t.to_s)

        # Buffer Passthrough - State change evaluation conditions

        # Move out of buffer feed if the required temperature rose above the limit
        # This logic is here to try forcing the heating back to direct heating in cases where
        # the heat generated can be dissipated. This a safety escrow
        # to try avoiding unnecessary buffer filling
        if @target_temp > @config[:buffer_passthrough_fwd_temp_limit] and @relax_timer.expired?
          $app_logger.debug("Target set above buffer_passthrough_fwd_temp_limit. State will change from buffer passthrough")
          $app_logger.debug("Decision: direct heat")

          set_relays(:direct_boiler)
          @heat_wiper.set_water_temp(@target_temp)

          @relax_timer.reset

          # If the buffer is nearly full - too low delta T or
          # too hot then start feeding from the buffer.
          # As of now we assume that the boiler is able to generate the output temp requred
          # therefore it is enough to monitor the deltaT to find out if the above condition is met
        elsif forward_temp > (@target_temp + @config[:buffer_passthrough_overshoot] + @config[:forward_above_target]) and @relax_timer.expired?
          $app_logger.debug("Overheating - buffer full. State will change from buffer passthrough")
          $app_logger.debug("Decision: Feed from buffer")

          if @heater_relay.state != :off
            $app_logger.debug("Turning off heater relay")
            @heater_relay.off
          end
          @heat_wiper.set_water_temp(7.0)
          $app_logger.debug("Waiting for boiler to stop before cutting it off from circulation")
          sleep @config[:circulation_maintenance_delay]

          set_relays(:feed_from_buffer)
          @relax_timer.reset

          # Buffer Passthrough - State maintenance operations
          # Just set the required water temperature
          # raised with the buffer filling offset
        else
          if @do_limited_rate_logging
            $app_logger.debug("Buffer Passthrough. Target: "+(@target_temp + @config[:buffer_passthrough_overshoot]).to_s)
            $app_logger.debug("Forward temp: "+forward_temp.to_s)
            $app_logger.debug("Delta_t: "+delta_t.to_s)
            @do_limited_rate_logging = false
          end
          @heat_wiper.set_water_temp(@target_temp + @config[:buffer_passthrough_overshoot])
          if @heater_relay.state != :on
            $app_logger.debug("Turning on heater relay")
            @heater_relay.on
          end
        end

        # Evaluate feed from Buffer state
      elsif @relay_state == :feed_from_buffer
        $app_logger.trace("Forward temp: "+forward_temp.to_s)
        $app_logger.trace("Target temp: "+@target_temp.to_s)

        # Feeed from Buffer - - State change evaluation conditions

        # If the buffer is empty: unable to provide at least the target temp minus the hysteresis
        # then it needs re-filling. This will ensure an operation of filling the buffer with
        # target+@config[:buffer_passthrough_overshoot] and consuming until target-@config[:buffer_expiry_threshold]
        # The effective hysteresis is therefore @config[:buffer_passthrough_overshoot]+@config[:buffer_expiry_threshold]
        if forward_temp < @target_temp - @config[:buffer_expiry_threshold]  and @relax_timer.expired?
          $app_logger.debug("Buffer empty - state will change from buffer feed")

          # If we are below the exit limit then go for filling the buffer
          # This starts off from zero (0), so for the first time it will need a limit set in
          # direct_boiler operation mode
          if @target_temp < @config[:buffer_passthrough_fwd_temp_limit]
            $app_logger.debug("Decision: fill buffer in buffer passthrough")

            @heat_wiper.set_water_temp(@target_temp + @config[:buffer_passthrough_overshoot])
            $app_logger.debug("Wait for boiler to pick up circulation before turning it on")
            sleep @config[:circulation_maintenance_delay]

            set_relays(:buffer_passthrough)
            if @heater_relay.state !=:on
              $app_logger.debug("Turning on heater relay")
              @heater_relay.on
            end

            @relax_timer.reset

            # If the target is above the exit limit then go for the direct feed
            # which in turn may set a viable exit limit
          else
            $app_logger.debug("Decision: target temp higher than passthrough limit - direct heat")
            set_relays(:direct_boiler)

            @heat_wiper.set_water_temp(@target_temp)
            $app_logger.debug("Wait for boiler to pick up circulation before turning it on")
            sleep @config[:circulation_maintenance_delay]

            if @heater_relay.state !=:on
              $app_logger.debug("Turning on heater relay")
              @heater_relay.on
            end
            @relax_timer.reset
          end
        end
        if @do_limited_rate_logging
          $app_logger.debug("Feed from buffer. Forward temp: "+forward_temp.to_s)
          $app_logger.debug("Delta_t: "+delta_t.to_s)
          @do_limited_rate_logging = false
        end
        @heat_wiper.set_water_temp(7.0)
        if @heater_relay.state != :off
          $app_logger.debug("Turning off heater relay")
          @heater_relay.off
        end
        # Raise an exception - no matching source state
      else
        raise "Unexpected logical relay state in set_heating_feed: "+@relay_state.to_s
      end
    end # of set_heating_feed

    # The actual tasks of the control thread
    def do_control

      if @control_log_rate_limiter > @config[:buffer_control_limited_log_period]
        @control_log_rate_limiter = 1
        @do_limited_rate_control_logging = true
      else
        @control_log_rate_limiter += 1
      end

      if @mode_changed
        $app_logger.debug("Heater control mode changed, got new mode: "+@mode.to_s)
        case @mode
        when :HW
          if @prev_mode == :heat
            $app_logger.debug("Remembering the relay state if coming to HW from heat: "+@relay_state.to_s)
            @prev_relay_state_in_prev_heating_mode = @relay_state
          end
          @hw_pump.on
          sleep @config[:circulation_maintenance_delay] if ( set_relays(:direct_boiler) != :delayed)
          @hydr_shift_pump.off
          @hw_wiper.set_water_temp(@hw_thermostat.temp)
        when :heat
          # Make sure HW mode of the boiler is off
          @hw_wiper.set_water_temp(65.0)
          @hydr_shift_pump.on
          sleep @config[:circulation_maintenance_delay]

          # Set back relays as they were when we left it off last time
          if @prev_mode != :off
            $app_logger.debug("Prev mode was not off it was: "+@prev_mode.to_s+" - setting relays to: "+@prev_relay_state_in_prev_heating_mode.to_s)
            set_relays(@prev_relay_state_in_prev_heating_mode)
          else
            $app_logger.debug("Prev mode was off - leaving relays as they are: "+@relay_state.to_s)
          end

          # Finalize state change
          @hw_pump.off
          $app_logger.debug("Resetting relax timer")
          @relax_timer.reset
          set_heating_feed
        else
          raise "Invalid mode in do_control after mode change. Expecting either ':HW' or ':heat' got: '"+@mode.to_s+"'"
        end
        @mode_changed = false
      else
        if @do_limited_rate_control_logging
          $app_logger.trace("Rate limited control logging\nHeater control mode not changed, mode is: "+@mode.to_s)
          @do_limited_rate_control_logging = false
        end
        case @mode
        when :HW
          @hw_wiper.set_water_temp(@hw_thermostat.temp)
        when :heat
          set_heating_feed
        else
          raise "Invalid mode in do_control. Expecting either ':HW' or ':heat' got: '"+@mode.to_s+"'"
        end
      end
    end

    # Control thread controlling functions
    # Start the control thread
    def start_control_thread
      # This section is synchronized to the control mutex.
      # Only a single control thread may exist
      return unless @control_mutex.try_lock

      # Set the stop thread signal inactive
      @stop_control.unlock if @stop_control.locked?

      # The controller thread
      @control_thread = Thread.new do
        $app_logger.debug("Heater control thread created")

        # Loop until signalled to exit
        while !@stop_control.locked?
          $config_mutex.synchronize {@config = $config.dup}
          @modesetting_mutex.synchronize do
            # Update any objects that may use parameters from the newly copied config
            update_config_items

            # Perform the actual periodic control loop actions
            do_control
          end
          sleep @config[:buffer_heat_control_loop_delay] unless @stop_control.locked?
        end
        # Stop heat production of the boiler
        if @heater_relay.state !=:off
          $app_logger.debug("Turning off heater relay")
          @heater_relay.off
        end
        $app_logger.debug("Heater control thread exiting")
      end # Of control Thread

    end # Of start_control_thread

    # Signal the control thread to stop
    def stop_control_thread
      # Only stop the control therad if it is alive
      return if !@control_mutex.locked? or @control_thread == nil

      # Signal control thread to exit
      @stop_control.lock
      # Wait for the thread to exit
      @control_thread.join

      # Unlock the thread lock so a new call to start_control_thread
      # can create the control thread
      @control_mutex.unlock
    end
  end
end