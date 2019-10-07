# frozen_string_literal: true

require '/usr/local/lib/boiler_controller/buscomm'
require '/usr/local/lib/boiler_controller/globals'
require '/usr/local/lib/boiler_controller/bus_device'
require '/usr/local/lib/boiler_controller/mixer_controller'
require 'rubygems'
require 'finite_machine'

module BoilerBase
  # The definition of the heating state machine
  class HeatingSM < FiniteMachine::Definition
    alias_target :controller

    events do
      event :turnon, off: :heating
      event :postheat, heating: :postheating
      event :posthw, heating: :posthwing
      event :turnoff, %i[postheating posthwing heating] => :off
      event :init, none: :off
    end

    callbacks do
      on_before do |event|
        controller.logger.info 'Heating state change from '\
                               "#{event.from} to #{event.to}"
      end
    end
  end
  # of class Heating SM

  # A low pass filter to filter out jitter from sensor data
  class Filter
    attr_reader :size
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
      @filter_mutex.synchronize { value_unsynced }
      @value
    end

    # Sensor is stable if the sample buffer is full and
    # all samples are within +-limit C from the median
    def stable?(stability_limit)
      return nil if @content.empty?

      # Copy a consistent state for calculations
      content = []
      avg = 0.0
      @filter_mutex.synchronize do
        content = @content.dup
        avg = value_unsynced
      end

      stable = true
      content.each { |x| stable &= (x - avg).abs < stability_limit }
      stable
    end

    def variance
      # Copy a consistent state for calculations
      content = []
      avg = 0.0
      @filter_mutex.synchronize do
        content = @content.dup
        avg = value_unsynced
      end
      sum = 0.0
      content.each { |v| sum += (v - avg)**2 }
      sum / content.size
    end

    def sigma
      Math.sqrt(variance)
    end

    private

    # Calculate value unsynchronized
    def value_unsynced
      return @value unless @dirty
      return nil if @content.empty?

      sum = 0
      @content.each { |element| sum += element }
      @value = sum.to_f / @content.size
      @dirty = false
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

    def set_threshold(new_threshold)
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
          th.modification_mutex.synchronize do
            initialized &= !th.target.nil?
            # @logger.debug(th.name + " initialized: #{!th.target.nil?}")
            # @logger.debug("Thermostats initialized: #{initialized}")
          end
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
            th.modification_mutex.synchronize do
              th.cycle_threshold = @timebase * th.value
              @logger
                .debug("#{th.name} pulse width set to: "\
                       "#{(th.cycle_threshold / @timebase * 100).round(0)}%")
            end
          end

          # Perform the cycle
          @sec_elapsed = 0
          while @sec_elapsed < @timebase
            any_thermostats_on = false
            @thermostat_instances.each do |th|
              if th.cycle_threshold > @sec_elapsed
                th.modification_mutex.synchronize do
                  if th.state != :on
                    th.state = :on
                    @logger.debug('Turning on ' + th.name)
                  end
                end
                any_thermostats_on = true
              else
                th.modification_mutex.synchronize do
                  if th.state != :off
                    th.state = :off
                    @logger.debug('Turning off ' + th.name)
                  end
                end
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
    attr_accessor :cycle_threshold, :state
    attr_reader :target, :name, :modification_mutex
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

    def update
      @modification_mutex.synchronize { @sample_filter.input_sample(@sensor.temp) }
    end

    def test_update(next_sample)
      @modification_mutex.synchronize { @sample_filter.input_sample(next_sample)}
    end

    def temp
      retval = 0
      @modification_mutex.synchronize { retval = @sample_filter.value }
      retval
    end

    def on?
      retval = false
      @modification_mutex.synchronize { retval = (@state == :on) }
      retval
    end

    def off?
      retval = false
      @modification_mutex.synchronize { retval = (@state == :off) }
      retval
    end

    def set_target(target)
      @modification_mutex.synchronize { @target = target }
    end

    def value
      @value_proc.call(@sample_filter, @target)
    end
  end
  # End of class PwmThermostat

  # The definition of the heating state machine
  class BufferSM < FiniteMachine::Definition
    alias_target :buffer

    events do
      event :turnoff, any: :off
      event :normal, any: :normal
      event :frombuffer, any: :frombuffer
      event :HW, any: :HW
      event :init, none: :off
    end
  end
  # of class BufferSM

  class BufferHeat
    attr_reader :forward_sensor, :upper_sensor, :buf_output_sensor, :return_sensor
    attr_reader :hw_sensor, :heat_return_sensor
    attr_reader :hw_valve
    attr_reader :heater_relay, :hydr_shift_pump, :hw_pump
    attr_reader :hw_wiper, :heat_wiper
    attr_reader :logger, :config
    attr_reader :heater_relax_timer
    attr_reader :target_temp
    attr_accessor :prev_sm_state
    # Initialize the buffer taking its sensors and control valves
    def initialize(forward_sensor, upper_sensor, buf_output_sensor, return_sensor,
                   heat_return_sensor,
                   hw_sensor,
                   hw_valve,
                   heater_relay,
                   hydr_shift_pump, hw_pump,
                   hw_wiper, heat_wiper,
                   config)

      # Buffer Sensors
      @forward_sensor = forward_sensor
      @upper_sensor = upper_sensor
      @buf_output_sensor = buf_output_sensor
      @return_sensor = return_sensor
      @heat_return_sensor = heat_return_sensor

      # HW_thermostat for filtered value
      @hw_sensor = hw_sensor

      # Valves
      @hw_valve = hw_valve

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
      @config = config
      @logger = config.logger.app_logger

      # This one signals the control thread to exit
      @stop_control = Mutex.new

      # This one is used to ensure atomicity of mode setting
      @modesetting_mutex = Mutex.new

      @control_log_rate_limiter = Globals::TimerSec.new(\
        @config[:buffer_control_log_period],
        'Buffer heater controller log timer'\
      )
      @heater_log_rate_limiter = Globals::TimerSec.new(\
        @config[:buffer_heater_log_period],
        'Buffer heater log period timer'\
      )

      # Create the state change relaxation timer
      @heater_relax_timer = Globals::TimerSec.new(\
        @config[:buffer_heater_state_change_relaxation_time],
        'Buffer heater state change relaxation timer'\
      )

      # Set the initial state
      @mode = @prev_mode = :off
      @control_thread = nil
      @relay_state = nil

      # Create the state machine of the buffer heater
      @buffer_sm = BufferSM.new
      @buffer_sm.target self

      set_sm_actions
      @buffer_sm.init

      @target_temp = 7.0
      @overshoot_required = false
      @forward_temp = @forward_sensor.temp
      @upper_temp = @upper_sensor.temp
      @heat_return_temp = @heat_return_sensor.temp
      @return_temp = @return_sensor.temp
      @delta_t = 0.0
    end

    # Update classes upon config_change
    def update_config_items
      @heater_relax_timer.set_timer(@config[:buffer_heater_state_change_relaxation_time])
      @control_log_rate_limiter.set_timer(@config[:buffer_control_log_period])
      @heater_log_rate_limiter.set_timer(@config[:buffer_heater_log_period])
    end

    # Set the operation mode of the buffer. This can take
    # the below values as a parameter:
    #
    # :heat - The system is configured for heating. Heat is provided
    #         by the boiler or by the buffer. The logic actively decides
    #         what to do and how the valves/heating relays need to be configured
    #
    # :off - The system is configured for being turned off. The remaining heat
    #        from the boiler - if any - is transferred to the buffer.
    #
    # :HW - The system is configured for HW - Boiler relays are switched off
    #       this now does not take the solar option into account.

    def set_mode(new_mode)
      # Check validity of the parameter
      raise "Invalid mode parameter '#{new_mode}' passed to set_mode(mode)"\
            unless %i[floorheat radheat off HW].include? new_mode

      # Take action only if the mode is changing
      return if @mode == new_mode

      @logger.debug("Heater set_mode. Got new mode: #{new_mode}")

      # Stop control if asked to do so
      if new_mode == :off
        stop_control_thread
        @prev_mode = @mode
        @mode = new_mode
        @mode_changed = true
        return
      end

      # Synchronize mode setting to the potentially running control thread
      @modesetting_mutex.synchronize do
        # Maintain a single level mode history and set the mode change flag
        @prev_mode = @mode
        @mode = new_mode
        @mode_changed = true
      end
      # of modesetting mutex sync

      # Start ontrol thread according to the new mode
      start_control_thread
    end
    # of set_mode

    # Set the required forward water temperature
    def set_target(new_target_temp, overshoot_required)
      @target_temp = new_target_temp
      @overshoot_required = overshoot_required
    end

    def state
      @buffer_sm.current
    end
    # Configure the relays for a certain purpose
    def set_relays(config)
      # Check validity of the parameter
      raise "Invalid relay config parameter '#{config}' passed to set_relays(config)"\
        unless %i[normal HW].include? config

      return :immediate if @relay_state == config

      @logger.info("Changing relay state: '#{@relay_state}' => '#{config}'")

      case config
      when :HW
        @hw_valve.on
        @relay_state = :HW
      when :normal
        @hw_valve.off
        @relay_state = :normal
      end

      @logger.debug('Waiting for relays to move into new position')

      # Wait until valve movement is complete
      sleep @config[:three_way_movement_time]
      :delayed
    end

    # Calculate limited boiler target watertemp taking overshoot into account
    def corrected_watertemp(watertemp)
      overshoot = if @overshoot_required
                    @config[:buffer_passthrough_overshoot]
                  else
                    0
                  end
      if watertemp + overshoot < @config[:minimum_heating_watertemp]
        @config[:minimum_heating_watertemp]
      else
        watertemp + overshoot
      end
    end

    private

    # Define  the state transition actions
    def set_sm_actions
      # :off, :normal, :frombuffer, :HW

      # Log state transitions and arm the state change relaxation timer
      @buffer_sm.on_before do |event|
        buffer.logger.debug('Bufferheater state change from '\
                          "#{event.from} to #{event.to}")
        buffer.prev_sm_state = event.from
        buffer.heater_relax_timer.reset
      end

      # On turning off the controller will take care of pumps
      # - Turn off HW production of boiler
      # - Turn off the heater relay
      @buffer_sm.on_enter_off do |event|
        if event.name == :init
          buffer.logger.debug('Bufferheater initializing')
          buffer.hw_wiper.set_water_temp(65.0)
          buffer.set_relays(:normal)
          buffer.heater_relay.off if buffer.heater_relay.on?
        else
          buffer.logger.debug('Bufferheater turning off')
          if buffer.heater_relay.on?
            buffer.heater_relay.off
            sleep buffer.config[:circulation_maintenance_delay]
          else
            buffer.logger.debug('Heater relay already off')
          end
        end
      end
      # of enter off action

      # On entering heat through buffer shifter
      # - Turn off HW production of boiler
      # - move relay to normal
      # - start the boiler
      # - Start the hydr shift pump
      @buffer_sm.on_enter_normal do
        buffer.hw_pump.off if buffer.hw_pump.on?
        buffer.heat_wiper.set_water_temp(\
          buffer.corrected_watertemp(buffer.target_temp)
        )
        buffer.hydr_shift_pump.on
        sleep buffer.config[:circulation_maintenance_delay] \
          if buffer.set_relays(:normal) == :immediate
        buffer.heater_relay.on
      end
      # of enter normal action

      # On entering heating from buffer set relays and turn off heating
      # - Turn off HW production of boiler
      @buffer_sm.on_enter_frombuffer do
        buffer.hw_pump.off if buffer.hw_pump.on?
        buffer.heater_relay.off if buffer.heater_relay.on?

        # Turn off hydr shift pump
        if buffer.hydr_shift_pump.on?
          # Wait for boiler to turn off safely
          buffer.logger.debug('Waiting for boiler to stop before '\
            'cutting it off from circulation')
          sleep buffer.config[:circulation_maintenance_delay]
          buffer.hydr_shift_pump.off
        end
      end
      # of enter frombuffer action

      # On entering HW
      # - Set relays to HW
      # - turn on HW pump
      # - start HW production
      # - turn off hydr shift pump
      @buffer_sm.on_enter_HW do
        buffer.hw_pump.on
        sleep buffer.config[:circulation_maintenance_delay] if\
          buffer.set_relays(:HW) != :delayed
        if buffer.hydr_shift_pump.on?
          buffer.hydr_shift_pump.off
        else
          buffer.logger.debug('Hydr shift pump already off')
        end
        buffer.hw_wiper.set_water_temp(buffer.hw_sensor.temp)
      end
      # of enter HW action

      # On exiting HW
      # - stop HW production
      # - Turn off hw pump in a delayed manner
      @buffer_sm.on_exit_HW do
        buffer.hw_wiper.set_water_temp(65.0)
        sleep buffer.config[:circulation_maintenance_delay]
      end
      # of exit HW action
    end
    # of setting up state machine callbacks - set_sm_actions

    #
    # Evaluate heating conditions and
    # set feed strategy
    # This routine only sets relays and heat switches no pumps
    # circulation is expected to be stable when called
    #
    def evaluate_heater_state_change
      @forward_temp = @forward_sensor.temp
      @upper_temp = @upper_sensor.temp
      @heat_return_temp = @heat_return_sensor.temp
      @return_temp = @return_sensor.temp

      # Evaluate Hydr shift Boiler states
      case @buffer_sm.current
        # Evaluate Buffer Fill state
      when :normal
        # Normal - State change evaluation conditions

        # If the buffer is nearly full - too low delta T or
        # too hot then start feeding from the buffer.
        # As of now we assume that the boiler is able to generate the
        # output temp requred therefore it is enough to monitor the
        # deltaT to find out if the above condition is met

        @delta_t = @forward_temp - @return_temp

        if @forward_temp > \
           (corrected_watertemp(@target_temp) + \
              @config[:forward_above_target]) &&
           @heater_relax_timer.expired?
          @logger.debug('Overheating - buffer full.'\
                            ' State will change from buffer normal')
          @logger.debug('Decision: Feed from buffer')
          @buffer_sm.frombuffer

          # Buffer Fill - State maintenance operations
          # Set the required water temperature raised with the buffer filling
          # offset Decide how ot set relays based on boiler state
        else
          @heat_wiper\
            .set_water_temp(corrected_watertemp(@target_temp))
          set_relays(:normal)
        end

        # Evaluate feed from Buffer state
      when :frombuffer

        # Feeed from Buffer - State change evaluation conditions
        # If the buffer is empty: unable to provide at least the target temp
        # minus the hysteresis then it needs re-filling. This will ensure an
        # operation of filling the buffer with
        # target+@config[:buffer_passthrough_overshoot] and consuming until
        # target-@config[:buffer_expiry_threshold]. The effective hysteresis
        # is therefore
        # @config[:buffer_passthrough_overshoot]+@config[:buffer_expiry_threshold]

        @delta_t = @upper_temp - @heat_return_temp

        if @upper_temp < @target_temp - @config[:buffer_expiry_threshold] && \
           @heater_relax_timer.expired?
          @logger.debug('Buffer empty - state will change from buffer feed')
          @logger.debug('Decision: normal')
          @buffer_sm.normal
          # of state evaluation
        end
        # of exit criteria evaluation

        # HW state
      when :HW
        @delta_t = @forward_temp - @return_temp
        # Just set the HW temp
        @hw_wiper.set_water_temp(@hw_sensor.temp)
      else
        raise 'Unexpected state in '\
              "evaluate_heater_state_change: #{@buffer_sm.current}"
      end

      feed_log
    end
    # of evaluate_heater_state_change

    # Perform mode change of the boiler
    def perform_mode_change
      # :floorheat,:radheat,:off,:HW
      # @mode contains the new mode
      # @prev_mode contains the prevoius mode
      @logger.debug("Heater control mode changed, got new mode: #{@mode}")

      case @mode
      when :HW
        @buffer_sm.HW
      when :floorheat, :radheat
        # Resume if in a heating mode before HW
        if @prev_mode == :HW && @prev_sm_state != :off
          @logger.debug("Ending HW - resuming state to: #{@prev_sm_state}")
          @buffer_sm.trigger(@prev_sm_state)

        # Start/continue in either of the two states based on conditions
        # Do oscillating buffer heating
        # start it either in normal or frombuffer based on
        # heat available in the buffer
        elsif @upper_sensor.temp > @target_temp - @config[:buffer_expiry_threshold]
          @logger.debug('Setting heating to frombuffer')
          @buffer_sm.frombuffer
        else
          @logger.debug('Setting heating to normal')
          @buffer_sm.normal
        end
      else
        raise 'Invalid mode in perform_mode_change. Expecting either '\
              "':HW', ':radheat' or ':floorheat' got: '#{@mode}'"
      end
    end

    # Control thread controlling functions
    # Start the control thread
    def start_control_thread
      # This section is synchronized to the control mutex.
      # Only a single control thread may exist
      #      return unless @control_mutex.try_lock

      unless @control_mutex.try_lock
        @logger.debug('Heater thread active - '\
          'control mutex locked returning')
        return
      end

      # Set the stop thread signal inactive
      @stop_control.unlock if @stop_control.locked?

      # The controller thread
      @control_thread = Thread.new do
        Thread.current[:name] = 'Heater control'
        @logger.debug('Heater control thread created')

        # Loop until signalled to exit
        until @stop_control.locked?
          # Make sure mode only changes outside of the block
          @modesetting_mutex.synchronize do
            # Update any objects that may use parameters from
            # the newly copied config
            update_config_items

            # Perform the actual periodic control loop actions
            if @mode_changed
              perform_mode_change
              @mode_changed = false
            else
              evaluate_heater_state_change
            end
          end
          sleep @config[:buffer_heat_control_loop_delay] unless\
                @stop_control.locked?
        end
        # Stop heat production of the boiler
        @logger.debug('Heater control turning off')
        @buffer_sm.turnoff
        @logger.debug('Heater control thread exiting')
      end
      # Of control Thread
    end
    # Of start_control_thread

    # Signal the control thread to stop
    def stop_control_thread
      @logger.debug('Heater stop_control_thread called')

      # Only stop the control therad if it is alive
      return if !@control_mutex.locked? || @control_thread.nil?

      @logger.debug('Control thread running: signalling it to stop')

      # Signal control thread to exit
      @stop_control.lock

      # Wait for the thread to exit
      @logger.debug('Waiting control thread to exit')
      @control_thread.join

      @logger.debug('Unlocking control mutex')
      # Unlock the thread lock so a new call to start_control_thread
      # can create the control thread
      @control_mutex.unlock

      @logger.debug('Control thread stopped')
    end
    # of stop_control_thread

    # Feed logging
    def feed_log
      do_limited_logging = false
      if @heater_log_rate_limiter.expired?
        do_limited_logging = true
        @heater_log_rate_limiter.reset
      else
        do_limited_logging = false
      end

      @logger.trace('--------------------------------')
      @logger.trace("Relax timer active: #{@heater_relax_timer.sec_left}")\
       unless @heater_relax_timer.expired?
      @logger.trace("Relay state: #{@relay_state}")
      @logger.trace("SM state: #{@buffer_sm.current}")

      @logger.debug("Heater mode: #{@mode}") if do_limited_logging

      case @buffer_sm.current
      when :normal
        @logger.trace("Forward temp: #{@forward_temp}")
        @logger.trace('Reqd./effective target temps: '\
          "#{@target_temp.round(2)}/#{@heat_wiper.get_target}")
        @logger.trace("Delta_t: #{@delta_t}")
        if do_limited_logging
          @logger.debug('Normal. Target: '\
            "#{corrected_watertemp(@target_temp).round(2)}")
          @logger.debug("Forward temp: #{@forward_temp}")
          @logger.debug('Deviation: '\
                        "#{(corrected_watertemp(@target_temp) - \
                        @forward_temp).round(2)}")
          @logger.debug("Buffer output temp: #{@upper_temp}")
          @logger.debug("Delta_t: #{@delta_t}")
        end
      when :frombuffer
        if do_limited_logging
          @logger.debug("Target temp: #{@target_temp.round(2)}")
          @logger.debug("Feed from buffer. Buffer output temp: #{@upper_temp}")
          @logger.debug('Headroom: '\
                        "#{(@upper_temp - \
                        (@target_temp - @config[:buffer_expiry_threshold]))\
                        .round(2)}")
          @logger.debug("Delta_t: #{@delta_t}")
        end
      when :HW
        if do_limited_logging
          @logger.debug("Forward temp: #{@forward_temp}")
          @logger.debug("Delta_t: #{@delta_t}")
        end
      end
    end
  end
  # of class Bufferheat
end
# of module BoilerBase
