require "/usr/local/lib/boiler_controller/Buscomm"
require "/usr/local/lib/boiler_controller/Globals"
require "/usr/local/lib/boiler_controller/bus_device"
require "rubygems"
require "robustthread"
require "finite_machine"

module BoilerBase
  # The definition of the heating state machine
  class HeatingSM < FiniteMachine::Definition

    alias_target :controller

    events {
      event :turnon, :off  => :heating
      event :postheat, :heating => :postheating
      event :posthw,  :heating => :posthwing
      event :turnoff, [:postheating, :posthwing, :heating] => :off
      event :init, :none => :off
    }

    callbacks {
      on_before {|event| $app_logger.debug("Heating state change from #{event.from} to #{event.to}")}
    }
  end # of class Heating SM

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
          @content.each do
            |element|
            sum += element
          end
          @value = sum.to_f / @content.size
          @dirty = false
        end
      end
      return @value
    end
  end # of class Filter

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
    attr_accessor :cycle_threshold, :state, :modification_mutex
    def initialize(sensor,filtersize,value_proc,is_HW_or_valve,timebase=3600)
      # Update the Class variables
      @@timebase = timebase
      @@is_HW_or_valve = is_HW_or_valve

      @sensor = sensor
      @sample_filter = Filter.new(filtersize)
      @value_proc = value_proc

      @modification_mutex = Mutex.new

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
        Thread.current[:name] = "PWM thermostat"
        #Wait for the main thread to create all objects we need
        sleep(10)
        while true

          @@newly_initialized_thermostat_present = false
          # Calculate the threshold value for each instance
          @@thermostat_instances.each do |th|
            th.modification_mutex.synchronize { th.cycle_threshold = @@timebase * th.value }
          end

          # Perform the cycle
          @@sec_elapsed = 0
          while @@sec_elapsed < @@timebase
            any_thermostats_on = false
            @@thermostat_instances.each do |th|
              if th.cycle_threshold > @@sec_elapsed
                th.modification_mutex.synchronize {th.state = :on}
                any_thermostats_on = true
              else
                th.modification_mutex.synchronize {th.state = :off}
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
      @modification_mutex.synchronize do
        # Request thread cycle restart if newly initialized
        @@newly_initialized_thermostat_present = (@@newly_initialized_thermostat_present or (@sample_filter.value == nil and @target != nil))
        @sample_filter.input_sample(@sensor.temp)
      end
    end

    def test_update(next_sample)
      @modification_mutex.synchronize { @sample_filter.input_sample(next_sample)}
    end

    def temp
      retval = 0
      @modification_mutex.synchronize { retval = @sample_filter.value }
      return retval
    end

    def is_on?
      retval = false
      @modification_mutex.synchronize { retval = (@state == :on) }
      return retval
    end

    def is_off?
      retval = false
      @modification_mutex.synchronize { retval = (@state == :off) }
      return retval
    end

    def set_target (target)
      @modification_mutex.synchronize do
        # Request thread cycle restart if newly initialized
        @@newly_initialized_thermostat_present = (@@newly_initialized_thermostat_present or (@target == nil and @sample_filter.value != nil))
        @target = target
      end
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
    def initialize(mix_sensor,cw_switch,ccw_switch,initial_target_temp=34.0)

      # Initialize class variables
      @mix_sensor = mix_sensor
      @target_temp = initial_target_temp
      @cw_switch = cw_switch
      @ccw_switch = ccw_switch

      # Copy the configuration
      @config = $config.dup

      # Create Filters
      @mix_filter = Filter.new(@config[:mixer_filter_size])

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

      # Create the log rate limiter
      @mixer_log_rate_limiter = Globals::TimerSec.new(@config[:mixer_limited_log_period],"Mixer controller log timer")
    end

    def temp
      @measurement_mutex.synchronize {value = @mix_filter.value}
      return value
    end

    def set_target_temp(new_target_temp)
      @target_mutex.synchronize {@target_temp = new_target_temp}
    end

    # Move it to the left
    def open
      open_thread = Thread.new do
        Thread.current[:name] = "Mixer opener"
        if @control_mutex.try_lock
          $app_logger.debug("Control mutex locked in open pulsing ccw for 31 secs")
          @ccw_switch.pulse_block(250)
          @ccw_switch.pulse_block(60)
          @control_mutex.unlock
          $app_logger.debug("Control mutex unlocked opening thread exiting")
        end
      end # of open thread
    end

    def start_control(delay=0)
      enter_timestamp = Time.now

      # Only start control thread if not yet started
      return unless @control_thread_mutex.try_lock

      $app_logger.debug("Mixer controller starting control")

      # Clear control thread stop sugnaling mutex
      @stop_control_requested.unlock if @stop_control_requested.locked?
      # Start control thread
      @control_thread = Thread.new do
        Thread.current[:name] = "Mixer controller"
        # Acquire lock for controlling switches
        @control_mutex.synchronize do

          # Delay starting the controller process if requested
          time_to_sleep = delay - (Time.now - enter_timestamp)
          sleep time_to_sleep if time_to_sleep > 0

          # Prefill sample buffer to get rid of false values
          @config[:mixer_filter_size].times do
            @mix_filter.input_sample(@mix_sensor.temp)
          end

          # Do the actual control, which will return ending the thread if done
          do_control_thread
        end # of control mutex synchronize
      end
    end

    def stop_control
      # Return if we do not have a control thread
      return if !@control_thread_mutex.locked? or @control_thread == nil

      # Signal the control thread to exit
      @stop_control_requested.lock
      # Wait for the control thread to exit
      @control_thread.join
      $app_logger.debug("Mixer controller control_thread joined")

      # Allow the next call to start control to create a new control thread
      @control_thread_mutex.unlock
      $app_logger.debug("Mixer controller control_thread_mutex unlocked")

    end

    def start_measurement_thread
      $app_logger.debug("Mixer controller - measurement thread start requested")
      return unless @measurement_thread_mutex.try_lock

      # Unlock the measurement thread exis signal
      @stop_measurement_requested.unlock if @stop_measurement_requested.locked?

      #Create a temperature measurement thread
      @measurement_thread = Thread.new do
        Thread.current[:name] = "Mixer measurement"
        $app_logger.debug("Mixer controller - measurement thread starting")
        while !@stop_measurement_requested.locked?
          @measurement_mutex.synchronize {@mix_filter.input_sample(@mix_sensor.temp) }
          sleep @config[:mixer_sampling_delay] unless @stop_measurement_requested.locked?
        end
        $app_logger.debug("Mixer controller - measurement thread exiting")
      end
    end

    def stop_measurement_thread
      # Return if we do not have a measurement thread
      return if !@measurement_thread_mutex.locked? or @measurement_thread == nil

      # Signal the measurement thread to exit
      @stop_measurement_requested.lock

      # Wait for the measurement thread to exit
      $app_logger.debug("Mixer controller - waiting for measurement thread to exit")
      @measurement_thread.join
      $app_logger.debug("Mixer controller - measurement thread joined")

      # Allow a next call to start_measurement thread to create
      # a new measurement thread
      @measurement_thread_mutex.unlock
      $app_logger.debug("Mixer controller - measurement_thread_mutex unlocked")
    end

    # The actual control thread
    def do_control_thread

      start_measurement_thread
      $app_logger.trace("Mixer controller do_control_thread before starting control loop")

      # Control until if stop is requested
      while !@stop_control_requested.locked?

        # Minimum delay between motor actuations
        sleep @config[:mixer_control_loop_delay]
        $app_logger.trace("Mixer controller do_control_thread in loop before sync target mutex")

        # Init local variables
        target = 0
        error = 0
        value = 0

        # Read target temp thread safely
        @target_mutex.synchronize { target = @target_temp }
        @measurement_mutex.synchronize do
          value = @mix_filter.value
          error = target - value
        end

        if @mixer_log_rate_limiter.expired?
          # Copy the config for updates
          $config_mutex.synchronize {@config = $config.dup}
          $app_logger.debug("Mixer forward temp: "+value.round(2).to_s)
          @mixer_log_rate_limiter.set_timer(@config[:mixer_limited_log_period])
          @mixer_log_rate_limiter.reset
        end

        # Adjust mixing motor if error is out of bounds
        if error.abs > @config[:mixer_error_threshold] and calculate_adjustment_time(error.abs) > 0

          adjustment_time = calculate_adjustment_time(error.abs)

          $app_logger.trace("Mixer controller target: "+target.round(2).to_s)
          $app_logger.trace("Mixer controller value: "+value.round(2).to_s)
          $app_logger.trace("Mixer controller error: "+error.round(2).to_s)
          $app_logger.trace("Mixer controller adjustment time: "+adjustment_time.round(2).to_s)

          # Move CCW
          if error > 0 and @integrated_ccw_movement_time < @config[:mixer_unidirectional_movement_time_limit]
            $app_logger.trace("Mixer controller adjusting ccw")
            @ccw_switch.pulse_block((adjustment_time*10).to_i)

            # Keep track of movement time for limiting movement
            @integrated_ccw_movement_time += adjustment_time

            # Adjust available movement time for the other direction
            @integrated_cw_movement_time = @config[:mixer_unidirectional_movement_time_limit] - @integrated_ccw_movement_time - @config[:mixer_movement_time_hysteresis]
            @integrated_cw_movement_time = 0 if @integrated_cw_movement_time < 0

            # Move CW
          elsif error < 0 and @integrated_cw_movement_time < @config[:mixer_unidirectional_movement_time_limit]
            $app_logger.trace("Mixer controller adjusting cw")
            @cw_switch.pulse_block((adjustment_time*10).to_i)

            # Keep track of movement time for limiting movement
            @integrated_cw_movement_time += adjustment_time

            # Adjust available movement time for the other direction
            @integrated_ccw_movement_time = @config[:mixer_unidirectional_movement_time_limit] - @integrated_cw_movement_time - @config[:mixer_movement_time_hysteresis]
            @integrated_ccw_movement_time = 0 if @integrated_ccw_movement_time < 0
          end
        end
      end

      # Stop the measurement thread before exiting
      stop_measurement_thread

      @integrated_cw_movement_time = 0
      @integrated_ccw_movement_time = 0

    end

    # Calculate mixer motor actuation time based on error
    # This implements a simple P type controller with limited boundaries
    def calculate_adjustment_time(error)
      retval = @config[:mixer_motor_time_parameter] * error
      return 0 if retval < 0
      return 5 if retval > 5
      return retval
    end
  end # of class MixerControl

  # The definition of the heating state machine
  class BufferSM < FiniteMachine::Definition

    alias_target :buffer

    events {
      event :turnoff, :any => :off
      event :hydrshift, :any => :hydrshift
      event :bufferfill, :any  => :bufferfill
      event :frombuffer, :any => :frombuffer
      event :HW, :any => :HW

      event :init, :none => :off
    }
  end # of class BufferSM

  class BufferHeat

    attr_reader :forward_sensor, :upper_sensor, :lower_sensor, :return_sensor
    attr_reader :hw_thermostat
    attr_reader :forward_valve, :return_valve,  :bypass_valve
    attr_reader :heater_relay, :hydr_shift_pump, :hw_pump
    attr_reader :hw_wiper, :heat_wiper
    attr_reader :config
    attr_reader :relax_timer
    attr_reader :heat_in_buffer, :target_temp
    attr_accessor :prev_sm_state
    # Initialize the buffer taking its sensors and control valves
    def initialize(forward_sensor, upper_sensor, lower_sensor, return_sensor,
      hw_thermostat,
      forward_valve, return_valve, bypass_valve,
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
      @bypass_valve = bypass_valve

      # Pump, heat relay
      @heater_relay = heater_relay
      @hydr_shift_pump = hydr_shift_pump
      @hw_pump = hw_pump

      # Temp wipers
      @hw_wiper = hw_wiper
      @heat_wiper = heat_wiper

      # This one ensures that there is only one control thread running
      @control_mutex = Mutex.new

      # Copy the configuration
      @config = $config.dup

      # This one signals the control thread to exit
      @stop_control = Mutex.new

      # This one is used to ensure atomicity of mode setting
      @modesetting_mutex = Mutex.new

      @control_log_rate_limiter = Globals::TimerSec.new(@config[:buffer_control_log_period],"Buffer heater controller log timer")
      @heater_log_rate_limiter = Globals::TimerSec.new(@config[:buffer_heater_log_period],"Buffer heater log period timer")

      # Create the state change relaxation timer
      @relax_timer = Globals::TimerSec.new(@config[:buffer_heater_state_change_relaxation_time],"Buffer heater state change relaxation timer")

      # Set the initial state
      @mode = @prev_mode = :off
      @control_thread = nil
      @relay_state = nil

      # Create the state machine of the buffer heater
      @buffer_sm = BufferSM.new
      @buffer_sm.target self

      set_sm_actions
      @buffer_sm.init

      @heat_in_buffer = {:temp=>@upper_sensor.temp,:percentage=>((@upper_sensor.temp - @config[:buffer_base_temp])*100)/(@lower_sensor.temp - @config[:buffer_base_temp])}
      @target_temp = 7.0
      @forward_temp = 7.0
      @delta_t = 0.0
      @boiler_on = false
    end

    # Update classes upon config_change
    def update_config_items
      @relax_timer.set_timer(@config[:buffer_heater_state_change_relaxation_time])
      @control_log_rate_limiter.set_timer(@config[:buffer_control_log_period])
      @heater_log_rate_limiter.set_timer(@config[:buffer_heater_log_period])
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
      raise "Invalid mode parameter '"+new_mode.to_s+"' passed to set_mode(mode)" unless [:floorheat,:radheat,:off,:HW].include? new_mode

      # Take action only if the mode is changing
      return if @mode == new_mode

      $app_logger.debug("Heater set_mode. Got new mode: "+new_mode.to_s)

      # Stop control if asked to do so
      if new_mode == :off
        stop_control_thread
        return
      end

      # Synchronize mode setting to the potentially running control thread
      @modesetting_mutex.synchronize do
        # Maintain a single level mode history and set the mode change flag
        @prev_mode = @mode
        @mode = new_mode
        @mode_changed = true
      end # of modesetting mutex sync

      # Start ontrol thread according to the new mode
      start_control_thread

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
      [:hydr_shifted,:buffer_passthrough,:feed_from_buffer,:HW].include? config

      return if @relay_state == config

      $app_logger.debug("Relay state is: '"+@relay_state.to_s+"'")
      $app_logger.debug("Setting relays to: '"+config.to_s+"'")
      moved = false

      case config
      when :hydr_shifted
        moved |= @forward_valve.state != :off
        @forward_valve.off
        moved |= @return_valve.state != :off
        @return_valve.off
        moved |= @bypass_valve.state != :off
        @bypass_valve.off
        @relay_state = :hydr_shifted
      when :buffer_passthrough
        moved |= @forward_valve.state != :off
        @forward_valve.off
        moved |= @return_valve.state != :on
        @return_valve.on
        moved |= @bypass_valve.state != :off
        @bypass_valve.off
        @relay_state = :buffer_passthrough
      when :feed_from_buffer
        moved |= @forward_valve.state != :on
        @forward_valve.on
        moved |= @return_valve.state != :off
        @return_valve.off
        moved |= @bypass_valve.state != :on
        @bypass_valve.on
        @relay_state = :feed_from_buffer
      when :HW
        $app_logger.debug("Don't care bypass valve is: "+@bypass_valve.state.to_s)
        moved |= @forward_valve.state != :off
        @forward_valve.off
        moved |= @return_valve.state != :off
        @return_valve.off
        @relay_state = :HW
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

    # Define  the state transition actions
    def set_sm_actions
      # :off, :hydrshift, :bufferfill, :frombuffer, :HW

      # Log state transitions and set the state change relaxation timer
      @buffer_sm.on_before do |event|
        $app_logger.debug("Bufferheater state change from #{event.from} to #{event.to}")
        buffer.prev_sm_state = event.from
        buffer.relax_timer.reset
      end

      # On turning off the controller will take care of pumps
      # - Turn off HW production of boiler
      # - Turn off the heater relay
      @buffer_sm.on_enter_off do |event|
        if event.from == :none
          $app_logger.debug("Bufferheater initializing")
          buffer.hw_wiper.set_water_temp(65.0)
          buffer.set_relays(:hydr_shifted)
          if  buffer.heater_relay.state == :on
            $app_logger.debug("Turning off heater relay")
            buffer.heater_relay.off
            sleep buffer.config[:circulation_maintenance_delay]
          else
            $app_logger.debug("Heater relay already off")
          end
        else
          $app_logger.debug("Bufferheater turning off")
          if  buffer.heater_relay.state == :on
            $app_logger.debug("Turning off heater relay")
            buffer.heater_relay.off
            sleep buffer.config[:circulation_maintenance_delay]
          else
            $app_logger.debug("Heater relay already off")
          end
          buffer.set_relays(:hydr_shifted)
        end
      end  # of enter off action

      # On entering heat through hydr shifter
      # - Turn off HW production of boiler
      # - move relays to boiler hydr shifted
      # - start the boiler
      # - Start the hydr shift pump
      @buffer_sm.on_enter_hydrshift do |event|
        buffer.heat_wiper.set_water_temp(buffer.target_temp)
        if buffer.hydr_shift_pump.state != :on
          $app_logger.debug("Turning on hydr shift pump")
          buffer.hydr_shift_pump.on
          sleep buffer.config[:circulation_maintenance_delay]
        else
          $app_logger.debug("Hydr shift pump already on")
        end
        buffer.set_relays(:hydr_shifted)
        if buffer.heater_relay.state != :on
          $app_logger.debug("Turning on heater relay")
          buffer.heater_relay.on
        else
          $app_logger.debug("Heater relay already on")
        end
      end # of enter hydrshift action

      # On entering heating from buffer set relays and turn off heating
      # - Turn off HW production of boiler
      @buffer_sm.on_enter_frombuffer do |event|
        if buffer.heater_relay.state != :off
          $app_logger.debug("Turning off heater relay")
          buffer.heater_relay.off

          # Wait for boiler tu turn off safely
          $app_logger.debug("Waiting for boiler to stop before cutting it off from circulation")
          sleep buffer.config[:circulation_maintenance_delay]
        else
          $app_logger.debug("Heater relay already off")
        end
        # Turn off hydr shift pump
        if buffer.hydr_shift_pump.state != :off
          $app_logger.debug("Turning off hydr shift pump")
          buffer.hydr_shift_pump.off
        end
        # Setup the relays
        buffer.set_relays(:feed_from_buffer)
      end # of enter frombuffer action

      # On entering heating bufferfill
      # - Turn off HW production of boiler
      # - Set relays to buffer passthrough
      # - turn on heating
      # - turn on hydr shift pump
      @buffer_sm.on_enter_bufferfill do |event|
        buffer.heat_wiper.set_water_temp(buffer.target_temp+buffer.config[:buffer_passthrough_overshoot])
        if buffer.hydr_shift_pump.state != :on
          $app_logger.debug("Turning on hydr shift pump")
          buffer.hydr_shift_pump.on
          sleep buffer.config[:circulation_maintenance_delay]
        else
          $app_logger.debug("Hydr shift pump already on")
        end
        buffer.set_relays(:buffer_passthrough)
        if buffer.heater_relay.state != :on
          $app_logger.debug("Turning on heater relay")
          buffer.heater_relay.on
        else
          $app_logger.debug("Heater relay already on")
        end
      end # of enter bufferfill action

      # On entering HW
      # - Set relays to HW
      # - turn on HW pump
      # - start HW production
      # - turn off hydr shift pump
      @buffer_sm.on_enter_HW do |event|
        $app_logger.debug("Turning on HW pump")
        buffer.hw_pump.on
        sleep buffer.config[:circulation_maintenance_delay] if (buffer.set_relays(:HW) != :delayed)
        if buffer.hydr_shift_pump.state != :off
          $app_logger.debug("Turning off hydr shift pump")
          buffer.hydr_shift_pump.off
        else
          $app_logger.debug("Hydr shift pump already off")
        end
        buffer.hw_wiper.set_water_temp(buffer.hw_thermostat.temp)
      end # of enter HW action

      # On exiting HW
      # - stop HW production
      # - Turn off hw pump in a delayed manner
      @buffer_sm.on_exit_HW do
        buffer.hw_wiper.set_water_temp(65.0)
        Thread.new do
          Thread.current[:name] = "HW exit"
          sleep buffer.config[:circulation_maintenance_delay]
          buffer.hw_pump.off
        end # of hw pump stopper delayed thread
      end # of exit HW action
    end # of setting up state machine callbacks - set_sm_actions

    #
    # Evaluate heating conditions and
    # set feed strategy
    # This routine only sets relays and heat switches no pumps
    # circulation is expected to be stable when called
    #
    def evaluate_heater_state_change

      @heat_in_buffer = {:temp=>@upper_sensor.temp,:percentage=>((@upper_sensor.temp - @config[:buffer_base_temp])*100)/(@lower_sensor.temp - @config[:buffer_base_temp])}

      @forward_temp = @forward_sensor.temp
      @delta_t = @forward_sensor.temp - @return_sensor.temp

      # For now just leave this logic out - introduce a boiler-on sensor later
      @boiler_on = true
      #      @boiler_on = ((@delta_t > @config[:boiler_on_detector_delta_t_threshold]) and
      #      (@forward_temp < (@target_temp + @config[:boiler_on_detector_max_target_overshoot])) and
      #      (@forward_temp > (@target_temp - @config[:boiler_on_detector_min_below_target])))

      feed_log

      # Evaluate Hydr shift Boiler states
      case @buffer_sm.current
      when :hydrshift

        # Hydr shift Boiler - State change condition evaluation
        if (@forward_temp > @target_temp + @config[:forward_above_target]) and
        @boiler_on and
        @relax_timer.expired?

          # Too much heat with hydr shift heat - let's either feed from buffer or fill the buffer
          # based on how much heat is stored in the buffer
          $app_logger.debug("Boiler overheating - state will change from "+@buffer_sm.current.to_s)
          $app_logger.debug("Heat in buffer: "+@heat_in_buffer[:temp].to_s+" Percentage: "+@heat_in_buffer[:percentage].to_s)

          if @heat_in_buffer[:temp] > @target_temp and
          @heat_in_buffer[:percentage] > @config[:init_buffer_reqd_fill_reserve]
            $app_logger.debug("Decision: Buffer contains enough heat - feed from buffer")
            @buffer_sm.frombuffer
          else
            $app_logger.debug("Decision: Buffer contains not much heat - fill buffer through the hydr shifter")
            @buffer_sm.bufferfill
          end

          # Hydr_shift - State maintenance operations
          # Just set the required water temperature
        else
          @heat_wiper.set_water_temp(@target_temp)
        end

        # Evaluate Buffer Fill state
      when :bufferfill
        # Buffer Fill - State change evaluation conditions

        # Move out of buffer fill if the required temperature rose above the limit
        # This logic is here to try forcing the heating back to hydr shift heating in cases where
        # the heat generated can be dissipated. This a safety escrow
        # to try avoiding unnecessary buffer filling
        if @target_temp > @config[:buffer_passthrough_fwd_temp_limit] and @relax_timer.expired?
          $app_logger.debug("Target set above buffer_passthrough_fwd_temp_limit. State will change from buffer passthrough")
          $app_logger.debug("Decision: hydr shifted")
          @buffer_sm.hydrshift

          # If the buffer is nearly full - too low delta T or
          # too hot then start feeding from the buffer.
          # As of now we assume that the boiler is able to generate the output temp requred
          # therefore it is enough to monitor the deltaT to find out if the above condition is met
        elsif @forward_temp > (@target_temp + @config[:buffer_passthrough_overshoot] + @config[:forward_above_target]) and
        @boiler_on and
        @relax_timer.expired?
          $app_logger.debug("Overheating - buffer full. State will change from buffer passthrough")
          $app_logger.debug("Decision: Feed from buffer")
          @buffer_sm.frombuffer

          # Buffer Fill - State maintenance operations
          # Set the required water temperature raised with the buffer filling offset
          # Decide how ot set relays based on boiler state
        else
          @heat_wiper.set_water_temp(@target_temp + @config[:buffer_passthrough_overshoot])
          @boiler_on ? set_relays(:buffer_passthrough) : set_relays(:hydr_shifted)
        end

        # Evaluate feed from Buffer state
      when :frombuffer

        # Feeed from Buffer - - State change evaluation conditions
        # If the buffer is empty: unable to provide at least the target temp minus the hysteresis
        # then it needs re-filling. This will ensure an operation of filling the buffer with
        # target+@config[:buffer_passthrough_overshoot] and consuming until target-@config[:buffer_expiry_threshold]
        # The effective hysteresis is therefore @config[:buffer_passthrough_overshoot]+@config[:buffer_expiry_threshold]
        if @forward_temp < @target_temp - @config[:buffer_expiry_threshold]  and @relax_timer.expired?
          $app_logger.debug("Buffer empty - state will change from buffer feed")

          # If in radheat mode then go back to hydr shift heat
          if @mode == :radheat
            $app_logger.debug("Radheat mode - Decision: Hydr shift")
            @buffer_sm.hydrshift

            # Else evaluate going back to bufferfill or hydr shift
          else
            # If we are below the exit limit then go for filling the buffer
            if @target_temp < @config[:buffer_passthrough_fwd_temp_limit]
              $app_logger.debug("Decision: fill buffer in buffer passthrough")
              @buffer_sm.bufferfill

              # If the target is above the exit limit then go for hydrshift mode
            else
              $app_logger.debug("Decision: target temp higher than passthrough limit - hydr shift heat")
              @buffer_sm.hydrshift
            end
          end # of state evaluation
        else
          # Well nothing needs to be done here at the moment but the block is
        end # of exit criterium evaluation
        # Raise an exception - no matching state

        # HW state
      when :HW
        # Just set the HW temp
        @hw_wiper.set_water_temp(@hw_thermostat.temp)
      else
        raise "Unexpected state in evaluate_heater_state_change: "+@buffer_sm.current.to_s
      end
    end # of evaluate_heater_state_change

    # The actual tasks of the control thread
    def do_control
      if @mode_changed
        #:floorheat,:radheat,:off,:HW

        $app_logger.debug("Heater control mode changed, got new mode: "+@mode.to_s)
        case @mode
        when :HW
          @buffer_sm.HW
        when :floorheat, :radheat

          # Resume the state if coming from HW and state was not off before HW
          if @prev_mode == :HW and @prev_sm_state != :off
            $app_logger.debug("Ending HW - resuming state to: "+@prev_sm_state.to_s)
            @buffer_sm.trigger(@prev_sm_state)
          else
            if @mode == :radheat and @buffer_sm.current == :bufferfill
              $app_logger.debug("Setting heating to hydr shifted")
              @buffer_sm.hydrshift
            elsif @buffer_sm.current == :off
              $app_logger.debug("Starting heating in hydr shift")
              @buffer_sm.hydrshift
            end
          end
        else
          raise "Invalid mode in do_control after mode change. Expecting either ':HW', ':radheat' or ':floorheat' got: '"+@mode.to_s+"'"
        end
        @mode_changed = false
      else
        $app_logger.trace("Do control not changing mode")
        controller_log
        evaluate_heater_state_change
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
        Thread.current[:name] = "Heater control"
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
        $app_logger.debug("Heater control turning off")
        @buffer_sm.turnoff
        $app_logger.debug("Heater control thread exiting")
      end # Of control Thread

    end # Of start_control_thread

    # Signal the control thread to stop
    def stop_control_thread

      $app_logger.debug("Heater stop_control_thread called")

      # Only stop the control therad if it is alive
      return if !@control_mutex.locked? or @control_thread == nil

      $app_logger.debug("Control thread running: signalling it to stop")

      # Signal control thread to exit
      @stop_control.lock

      # Wait for the thread to exit
      $app_logger.debug("Waiting control thread to exit")
      @control_thread.join

      # Unlock the thread lock so a new call to start_control_thread
      # can create the control thread
      @control_mutex.unlock
    end # of stop_control_thread

    def controller_log
      do_limited_logging = false
      if @control_log_rate_limiter.expired?
        do_limited_logging = true
        @control_log_rate_limiter.reset
      else
        do_limited_logging = false
      end

      if do_limited_logging
        $app_logger.debug("Heater mode: "+@mode.to_s)
      end
    end

    # Feed logging
    def feed_log
      do_limited_logging = false
      if @heater_log_rate_limiter.expired?
        do_limited_logging = true
        @heater_log_rate_limiter.reset
      else
        do_limited_logging = false
      end

      $app_logger.trace("--------------------------------")
      $app_logger.trace("Relax timer active: "+@relax_timer.sec_left.to_s) if !@relax_timer.expired?
      $app_logger.trace("Relay state: "+@relay_state.to_s)
      $app_logger.trace("SM state: "+@buffer_sm.current.to_s)
      $app_logger.trace("Boiler state: "+(@boiler_on ? "on" : "off"))

      #      $app_logger.debug("Forward temp: "+@forward_temp.to_s)
      #      $app_logger.debug("Delta_t: "+@delta_t.to_s)
      #      @boiler_on ? $app_logger.debug("Boiler detected : on") : $app_logger.debug("Boiler detected : off")

      case @buffer_sm.current
      when :hydrshift
        $app_logger.trace("Forward temp: "+@forward_temp.to_s)
        $app_logger.trace("Target temp: "+@target_temp.to_s)
        $app_logger.trace("Threshold forward_above_target: "+@config[:forward_above_target].to_s)
        $app_logger.trace("Delta_t: "+@delta_t.to_s)
        if do_limited_logging
          $app_logger.debug("HydrShift heating. Target: "+@target_temp.to_s)
          $app_logger.debug("Forward temp: "+@forward_temp.to_s)
          $app_logger.debug("Delta_t: "+@delta_t.to_s)
          @boiler_on ? $app_logger.debug("Boiler detected : on") : $app_logger.debug("Boiler detected : off")
        end
      when :bufferfill
        $app_logger.trace("Forward temp: "+@forward_temp.to_s)
        $app_logger.trace("Reqd./effective target temps: "+@target_temp.to_s+"/"+@heat_wiper.get_target.to_s)
        $app_logger.trace("buffer_passthrough_fwd_temp_limit: "+@config[:buffer_passthrough_fwd_temp_limit].to_s)
        $app_logger.trace("Delta_t: "+@delta_t.to_s)
        if do_limited_logging
          $app_logger.debug("Buffer Passthrough. Target: "+(@target_temp + @config[:buffer_passthrough_overshoot]).to_s)
          $app_logger.debug("Forward temp: "+@forward_temp.to_s)
          $app_logger.debug("Delta_t: "+@delta_t.to_s)
          @boiler_on ? $app_logger.debug("Boiler detected : on") : $app_logger.debug("Boiler detected : off")
        end
      when :frombuffer
        $app_logger.trace("Forward temp: "+@forward_temp.to_s)
        $app_logger.trace("Target temp: "+@target_temp.to_s)
        if do_limited_logging
          $app_logger.debug("Feed from buffer. Forward temp: "+@forward_temp.to_s)
          $app_logger.debug("Delta_t: "+@delta_t.to_s)
        end
      when :HW
        if do_limited_logging
          $app_logger.debug("Forward temp: "+@forward_temp.to_s)
          $app_logger.debug("Delta_t: "+@delta_t.to_s)
        end
      end
    end

  end # of class Bufferheat
end # of module BoilerBase