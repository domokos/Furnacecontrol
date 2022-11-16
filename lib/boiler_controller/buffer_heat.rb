# frozen_string_literal: true

require '/usr/local/lib/boiler_controller/heatpump'

# Class of the buffer heater
class BufferHeat
  attr_reader :forward_sensor, :upper_sensor, :buf_output_sensor, :return_sensor,
              :hw_sensor, :heat_return_sensor,
              :hw_valve, :bufferbypass_valve,
              :heater_relay, :hp_relay, :heatpump,
              :hydr_shift_pump, :hw_pump,
              :hw_wiper, :heat_wiper,
              :logger, :config,
              :heater_relax_timer,
              :target_temp
  attr_accessor :prev_sm_state

  # Initialize the buffer taking its sensors and control valves
  def initialize(forward_sensor, upper_sensor, buf_output_sensor, return_sensor,
                 heat_return_sensor,
                 hw_sensor,
                 hw_valve, bufferbypass_valve,
                 heater_relay, hp_relay, hp_dhw_wiper,
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
    @bufferbypass_valve = bufferbypass_valve

    # Pump, heat relay
    @heater_relay = heater_relay
    @hp_relay = hp_relay
    @hp_dhw_wiper = hp_dhw_wiper
    @hydr_shift_pump = hydr_shift_pump
    @hw_pump = hw_pump

    @heatpump = HeatPump.new(config)

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
    @buffer_sm = BufferStates::BufferSM.new(self)

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
    @heater_relax_timer.timer = @config[:buffer_heater_state_change_relaxation_time]
    @control_log_rate_limiter.timer = @config[:buffer_control_log_period]
    @heater_log_rate_limiter.timer = @config[:buffer_heater_log_period]
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
  # :hw - The system is configured for HW - Boiler relays are switched off
  #       this now does not take the solar option into account.

  def mode=(new_mode)
    # Check validity of the parameter
    raise "Invalid mode parameter '#{new_mode}' passed to set_mode(mode)"\
          unless %i[floorheat radheat off HW].include? new_mode

    # Take action only if the mode is changing
    return if @mode == new_mode

    @logger.debug("Heater mode set. Got new mode: #{new_mode}")

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
    unless %i[normal hw].include? config

    return :immediate if @relay_state == config

    @logger.info("Changing relay state: '#{@relay_state}' => '#{config}'")

    case config
    when :hw
      @hw_valve.on
      @bufferbypass_valve.on
      @relay_state = :hw
    when :normal
      @hw_valve.off
      @bufferbypass_valve.off
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
    @hw_temp = @hw_sensor.temp

    # Evaluate Hydr shift Boiler states
    case @buffer_sm.current
    # Evaluate Buffer Fill state
    when :normal
      set_relays(:normal)
    # Normal - State change evaluation conditions

    # If the buffer is nearly full - too low delta T or
    # too hot then start feeding from the buffer.
    # As of now we assume that the boiler is able to generate the
    # output temp requred therefore it is enough to monitor the
    # deltaT to find out if the above condition is met
=begin
    @delta_t = @forward_temp - @return_temp

    if (@forward_temp > \
        (corrected_watertemp(@target_temp) + \
            @config[:forward_above_target])) &&
        @heater_relax_timer.expired?
        @logger.debug('Overheating - buffer full.'\
                        ' State will change from buffer normal')
        @logger.debug('Decision: Feed from buffer')
        @buffer_sm.frombuffer

        # Buffer Fill - State maintenance operations
        # Set the required water temperature raised with the buffer filling
        # offset Decide how ot set relays based on boiler state
    else
        # @heat_wiper\
        #  .set_water_temp(corrected_watertemp(@target_temp))
        set_relays(:normal)
    end
=end
      @heatpump.heating_targettemp = corrected_watertemp(@target_temp)
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
    when :hw
      @delta_t = @forward_temp - @return_temp
      hw_pump.on if @heatpump.forward_temp > @hw_temp + 7
      # Just set the HW temp
      # @hw_wiper.set_water_temp(@hw_sensor.temp)
    else
      @logger.debug('Unexpected state in '\
        "evaluate_heater_state_change: #{@buffer_sm.current}")
      raise 'Unexpected state in '\
            "evaluate_heater_state_change: #{@buffer_sm.current}"
    end

    feed_log
  end
  # of evaluate_heater_state_change

  # Perform mode change of the boiler
  def perform_mode_change
    # :floorheat,:radheat,:off,:hw
    # @mode contains the new mode
    # @prev_mode contains the prevoius mode
    @logger.debug("Heater control mode changed, got new mode: #{@mode}")

    case @mode
    when :HW
      @buffer_sm.dhw
    when :floorheat, :radheat
=begin
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
=end
      @logger.debug('Setting heating to normal')
      @buffer_sm.normal
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
