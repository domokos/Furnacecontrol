# frozen_string_literal: true

require '/usr/local/lib/boiler_controller/boiler_base'
require '/usr/local/lib/boiler_controller/heating_sm'
require '/usr/local/lib/boiler_controller/buffer_heat'
require 'rubygems'

# Class of the heating controller
class HeatingController
  attr_reader :mixer_controller, :buffer_heater, :heating_watertemp,
              :radiator_pump, :floor_pump, :hw_watertemp, :heater_relay,
              :hydr_shift_pump, :hot_water_pump, :basement_floor_valve,
              :basement_radiator_valve,
              :living_floor_valve, :upstairs_floor_valve,
              :forward_temp, :return_temp, :output_temp, :heat_return_temp,
              :hw_thermostat, :living_thermostat, :hp_heating_mode_active,
              :upstairs_thermostat, :basement_thermostat,
              :cold_outside_thermostat,
              :mode_thermostat, :target_boiler_temp,
              :sm_relax_timer, :defrost,
              :logger, :config, :state_history

  def initialize(config)
    # Init instance variables
    @target_boiler_temp = 0.0
    @forward_temp = 0.0
    @return_temp = 0.0
    @test_cycle_cnt = 0
    @moving_valves_required = false
    @logger = config.logger.app_logger
    @heating_logger = config.logger.heating_logger
    @config = config
    @defrost = false

    read_config

    @logger_timer =
      Globals::TimerSec.new(@config[:logger_delay_whole_sec],
                            'Logging Delay Timer')

    @homebus_device_base = BusDevice::DeviceBase\
                           .new(@config)

    require '/usr/local/lib/boiler_controller/heating_devices'

    create_pumps

    create_sensors

    create_valueprocs

    create_devices

    # Create the heating state machine
    @heating_sm = HeatingStates::HeatingSM.new(self)

    @sm_relax_timer = Globals::TimerSec.new(\
      @config[:heating_sm_state_change_relaxation_time],
      'Buffer SM state change relaxation timer'\
    )

    prefill_sensors

    # Set the initial state
    @heating_sm.init

    @mode = :mode_Off

    # Create watertemp Polycurves
    @heating_watertemp_polycurve = \
      Globals::Polycurve.new(@config[:heating_watertemp_polycurve])
    @floor_watertemp_polycurve = \
      Globals::Polycurve.new(@config[:floor_watertemp_polycurve])
    @hw_watertemp_polycurve = \
      Globals::Polycurve.new(@config[:HW_watertemp_polycurve])

    # Set initial HW target
    @hw_thermostat.threshold = @hw_watertemp_polycurve\
                               .float_value(@floor_thermostat.temp)
    # Threshold not used in this case just set it to zero
    @cold_outside_thermostat.target = 0

    @logger.debug('Boiler controller initialized initial state '\
                      "set to: #{@heating_sm.current}, "\
                      "Initial mode set to: #{@mode}")
  end

  private

  # Prefill sensors and thermostats to ensure smooth startup operation
  def prefill_sensors
    6.times do |i|
      @logger.info("Prefilling sensors. Round: #{i + 1} of 6")
      read_sensors
      sleep 0.5
      @config.shutdown_reason != Globals::NO_SHUTDOWN && break
    end
  end

  # The function evaluating states and performing necessary
  # transitions basd on the current value of sensors
  def evaluate_state_change(power_needed)
    if !@sm_relax_timer.expired? && power_needed[:power] != :NONE
      @logger.trace('SM relax timer not expired - not changing state')
      return
    end

    case @heating_sm.current
    # The evaluation of the off state
    when :off
      # Evaluating Off state:
      # If need power then -> heating
      # Else: Stay in off state

      if power_needed[:power] != :NONE
        @logger.debug("Need power is : #{power_needed[:power]}")
        @heating_sm.turnon
      else
        @logger.trace('Decision: No power requirement - not changing state')
      end

    when :heating
      # Evaluating Heat state:
      # Control valves and pumps based on measured temperatures
      # Control boiler wipers to maintain target boiler temperature
      # If not need power anymore then -> postheating or
      # posthw based on operating mode

      if power_needed[:power] == :NONE
        @logger.debug('Need power is: NONE turning off')
        @heating_sm.turnoff
      end
=begin
      if power_needed[:power] == :NONE
        case buffer_heater.state
        when @mode == :mode_Heat_HW && :HW
          @logger.debug('Need power is: NONE coming from HW in Heat_HW mode')
          # Turn off the heater
          @heating_sm.postheat
        when @mode == :mode_HW && :HW
          @logger.debug('Need power is: NONE coming from HW in HW mode')
          # Turn off the heater
          @heating_sm.posthw
        when :normal
          @logger.debug('Need power is: NONE coming from normal heating')
          # Turn off the heater
          @heating_sm.postheat
        when :frombuffer
          @logger.debug('Need power is: NONE coming from heat from buffer')
          # Turn off the heater
          @heating_sm.turnoff
        else
          raise 'Unexpected heater state in '\
                "evaluate_state_change: #{buffer_heater.state}"
        end
      end
=end
    when :postheating
      # Evaluating postheating state:
      # If Delta T on the Boiler drops below 5 C then -> off
      # If need power is not false then -> heat
      # If Delta T on the Boiler drops below 5 C then -> off

      if @forward_temp - @return_temp < 5.0
        @logger.debug('Delta T on the boiler dropped below 5 C')
        # Turn off the heater
        @heating_sm.turnoff
        # If need power then -> Heat
      elsif power_needed[:power] != :NONE
        @logger.debug("Need power is #{power_needed[:power]}")
        @heating_sm.turnon
      end

    when :posthwing
      # Evaluating PostHW state:
      # If Delta T on the Boiler drops below 5 C then -> Off
      # If Boiler temp below HW temp + 4 C then -> Off
      # If need power is not false then -> Heat
      # If Delta T on the Boiler drops below 5 C then -> Off

      if @forward_temp - @return_temp < 5.0
        @logger.debug('Delta T on the Boiler dropped below 5 C')
        # Turn off the heater
        @heating_sm.turnoff
        # If Boiler temp below HW temp + 4 C then -> Off
      elsif @forward_temp < @hw_thermostat.temp + 4
        @logger.debug('Boiler temp below HW temp + 4 C')
        # Turn off the heater
        @heating_sm.turnoff
        # If need power then -> Heat
      elsif power_needed[:power] != :NONE
        @logger.debug("Need power is #{power_needed[:power]}")
        # Turn off the heater
        @heating_sm.turnoff
      end
    end
  end

  # Read the temperature sensors
  def read_sensors
    @forward_temp = @forward_sensor.temp
    @hw_thermostat.update
    @return_temp = @return_sensor.temp
    @upper_buffer_temp = @upper_buffer_sensor.temp
    @heat_return_temp = @heat_return_sensor.temp
    @output_temp = @output_sensor.temp
    @living_thermostat.update
    @upstairs_thermostat.update
    @basement_thermostat.update
    @cold_outside_thermostat.update
    @floor_thermostat.update
    @mode_thermostat.update

    @defrost = buffer_heater.heatpump.fan_rpm.zero? &&
               buffer_heater.heatpump.compressor_rpm.zero? &&
               buffer_heater.hp_relay.on?
  end

  public

  # The main loop of the controller
  def operate
    @state_history = Array.new(4, state: @heating_sm.current,
                                  power: determine_power_needed,
                                  timestamp: Time.now.getlocal(0))

    prev_power_needed = { state: :Off, power: :NONE,
                          timestamp: Time.now.getlocal(0) }
    power_needed = { state: @heating_sm.current, power: determine_power_needed,
                     timestamp: Time.now.getlocal(0) }

    # Do the main loop until shutdown is requested
    while @config.shutdown_reason == Globals::NO_SHUTDOWN

      @logger.trace('Main boiler loop cycle start')

      # Sleep to save processor time
      sleep @config[:main_loop_delay]

      # Apply the test conrol if in dry run
      apply_test_control if DRY_RUN

      # Determinde power needed - its cahange
      # and real heating tartgets if not in dry run
      unless DRY_RUN
        read_sensors
        temp_power_needed = { state: @heating_sm.current,
                              power: determine_power_needed,
                              timestamp: Time.now.getlocal(0) }
        prev_power_needed = power_needed

        if temp_power_needed[:state] != power_needed[:state] ||
           temp_power_needed[:power] != power_needed[:power]
          power_needed = temp_power_needed

          # Record state history for the last 4 states
          @state_history.shift
          @state_history.push(power_needed)
        end
        determine_targets(power_needed)
      end

      # Call the state machine state transition decision method
      evaluate_state_change(power_needed)

      # Conrtol heating when in heating state
      if @heating_sm.current == :heating
        # Control heat
        control_heat(prev_power_needed, power_needed)

        # Control valves and pumps
        control_pumps_valves_for_heating(prev_power_needed, power_needed)
      end

      # Perform cycle logging
      app_cycle_logging(power_needed)
      heating_cycle_logging(power_needed)

      # Evaluate if moving valves is required and
      # schedule a movement cycle if needed
      valve_move_evaluation

      # If magnetic valve movement is required then carry out moving process
      # and reset movement required flag
      if @moving_valves_required && @heating_sm.current == :off
        do_magnetic_valve_movement
        @moving_valves_required = false
      end
    end
    @logger.debug('Main cycle ended shutting down')
    shutdown
  end

  private

  # Read the target temperatures, determine targets and operating mode
  def determine_targets(power_needed)
    # Update thermostat targets
    @living_thermostat.threshold = @config[:target_living_temp]
    @upstairs_thermostat.threshold = @config[:target_upstairs_temp]
    @basement_thermostat.target = @config[:target_basement_temp]
    @mode_thermostat.threshold = @config[:mode_threshold]
    @mode_thermostat.hysteresis = @config[:mode_hysteresis]

    @floor_thermostat.threshold = @config[:floor_heating_threshold]

    # Update watertemp Polycurves
    @heating_watertemp_polycurve.load(@config[:heating_watertemp_polycurve])
    @floor_watertemp_polycurve.load(@config[:floor_watertemp_polycurve])
    @hw_watertemp_polycurve.load(@config[:HW_watertemp_polycurve])

    new_mode = @mode_thermostat.on? ? :mode_Heat_HW : :mode_HW
    if @mode != new_mode
      @logger.debug("Mode changed to: #{new_mode}")
      @mode = new_mode
    end

    case power_needed[:power]
    when :HW
      # Leave the heating wiper where it is.
      # Set HW target temp only when in HW mode to avoid
      # sneak climbing of HW target
      @hw_thermostat.threshold = @hw_watertemp_polycurve\
                                 .float_value(@floor_thermostat.temp)

    when :RAD
      @target_boiler_temp = @heating_watertemp_polycurve\
                            .float_value(@floor_thermostat.temp)

    when :RADFLOOR
      # Set target to the higher value
      @target_boiler_temp =
        if @heating_watertemp_polycurve.float_value(@floor_thermostat.temp) >
           @floor_watertemp_polycurve.float_value(@floor_thermostat.temp)
          @heating_watertemp_polycurve.float_value(@floor_thermostat.temp)
        else
          @floor_watertemp_polycurve.float_value(@floor_thermostat.temp)
        end

      @mixer_controller.target_temp = @floor_watertemp_polycurve\
                                      .float_value(@floor_thermostat.temp)

    when :FLOOR
      @target_boiler_temp = @floor_watertemp_polycurve\
                            .float_value(@floor_thermostat.temp)
      @mixer_controller.target_temp = @floor_watertemp_polycurve\
                                      .float_value(@floor_thermostat.temp)

    when :NONE
      @target_boiler_temp = 7.0

    end
    # End of determine_targets
  end

  # Control heating
  def control_heat(prev_power_needed, power_needed)
    changed = ((prev_power_needed[:power] != power_needed[:power]) || \
    (prev_power_needed[:state] != power_needed[:state]))

    case power_needed[:power]
    when :HW
      return unless changed

      # Set mode of the heater
      @logger.debug('Setting heater mode to HW')
      @buffer_heater.mode = :HW
      @mixer_controller.pause
    when :RAD, :RADFLOOR, :FLOOR
      # Set mode and required water temperature of the boiler
      @logger.trace("Setting heater target temp to: #{@target_boiler_temp}")
      @buffer_heater.set_target(@target_boiler_temp,\
                                power_needed[:power] != :RAD)
      if power_needed[:power] == :FLOOR && changed
        @logger.debug('Setting heater mode to :floorheat')
        @buffer_heater.mode = :floorheat
      elsif changed
        @logger.debug('Setting heater mode to :radheat')
        @buffer_heater.mode = :radheat
      end
      if power_needed[:power] == :RAD
        @mixer_controller.pause
      else
        @mixer_controller.resume
      end
    else
      @logger.fatal('Unexpected power_needed encountered '\
      "in control_heat: #{power_needed[:power]}")
      raise 'Unexpected power_needed encountered in control_heat: '\
      "#{power_needed[:power]}"
    end
  end

  # This function controls valves, pumps and heat
  # during heating by evaluating the required power
  def control_pumps_valves_for_heating(prev_power_needed, power_needed)
    changed = ((prev_power_needed[:power] != power_needed[:power]) || \
    (prev_power_needed[:state] != power_needed[:state]))

    @logger.trace('Setting valves and pumps')

    case power_needed[:power]
    when :HW # Only Hot water supplies on
      if changed
        @logger.info('Setting valves and pumps for HW')

        # Turn off pumps
        @radiator_pump.off
        @floor_pump.off

        # All valves are closed
        @basement_floor_valve.delayed_close
        @basement_radiator_valve.delayed_close
        @living_floor_valve.delayed_close
        @upstairs_floor_valve.delayed_close
      end
    when :RAD # Only Radiator pumps on
      #  decide on basement radiator valve
      if @basement_thermostat.on?
        @basement_radiator_valve.open
      else
        @basement_radiator_valve.delayed_close
      end

      if changed
        @logger.info('Setting valves and pumps for RAD')
        @basement_floor_valve.delayed_close
        @living_floor_valve.delayed_close
        @upstairs_floor_valve.delayed_close

        # Floor heating off
        @floor_pump.off
      end

      unless @radiator_pump.on?
        @logger.info('Turning radiator pump on')
        # Radiator pump on
        @radiator_pump.on
      end

    when :RADFLOOR
      # decide on basement valves based on basement temperature
      if @basement_thermostat.on?
        @basement_radiator_valve.open
        @basement_floor_valve.open
      else
        @basement_radiator_valve.delayed_close
        @basement_floor_valve.delayed_close
      end

      # decide on floor valves based on external temperature
      if @floor_thermostat.on?
        @living_floor_valve.open
        @upstairs_floor_valve.open
      else
        @living_floor_valve.delayed_close
        @upstairs_floor_valve.delayed_close
      end

      @logger.info('Setting valves and pumps for RADFLOOR') if changed

      if @radiator_pump.off? || @floor_pump.off?
        @logger.info('Turning radiator and floor pumps on')
        # Radiator pump on
        @radiator_pump.on
        @floor_pump.on
      end

    when :FLOOR
      # decide on basement valve based on basement temperature
      if @basement_thermostat.on?
        @basement_floor_valve.open
      else
        @basement_floor_valve.delayed_close
      end

      # decide on floor valves based on external temperature
      if @floor_thermostat.on?
        @living_floor_valve.open
        @upstairs_floor_valve.open
      else
        @living_floor_valve.delayed_close
        @upstairs_floor_valve.delayed_close
      end

      if changed
        @logger.info('Setting valves and pumps for FLOOR')
        @basement_radiator_valve.delayed_close

        @radiator_pump.off
      end

      unless @floor_pump.on?
        @logger.info('Turning floor pump on')
        # Floor pump on
        @floor_pump.on
      end
    end
  end

  # This function tells what kind of  power is needed
  def determine_power_needed
    if @moving_valves_required
      :NONE
    elsif @mode != :mode_Off && @hw_thermostat.on?
      # Power needed for hot water - overrides Heat power need
      :HW
    elsif @mode == :mode_Heat_HW && (@upstairs_thermostat.on? || \
          @living_thermostat.on? || cold_outside_thermostat.on?) && \
          @floor_thermostat.off? && \
          @basement_thermostat.off?
      # Power needed for heating
      :RAD
    elsif @mode == :mode_Heat_HW && (@upstairs_thermostat.on? || \
          @living_thermostat.on? || cold_outside_thermostat.on?) && \
          (@floor_thermostat.on? || \
          @basement_thermostat.on?)
      # Power needed for heating and floor heating
      :RADFLOOR
    elsif @mode == :mode_Heat_HW && (@floor_thermostat.on? || \
          @basement_thermostat.on?)
      # Power needed for floor heating only
      :FLOOR
    else
      # No power needed
      :NONE
    end
  end

  def read_config
    @config.reload

    @forward_sensor.mock_temp = @config[:forward_mock_temp]\
      unless (defined? @forward_sensor).nil?
    @return_sensor.mock_temp = @config[:return_mock_temp]\
      unless (defined? @return_sensor).nil?
    @hw_sensor.mock_temp = @config[:HW_mock_temp]\
      unless (defined? @hw_sensor).nil?

    @living_sensor.mock_temp = @config[:living_mock_temp]\
      unless (defined? @living_sensor).nil?
    @upstairs_sensor.mock_temp = @config[:upstairs_mock_temp]\
      unless (defined? @upstairs_sensor).nil?
    @basement_sensor.mock_temp = @config[:basement_mock_temp]\
      unless (defined? @basement_sensor).nil?
    @external_sensor.mock_temp = @config[:external_mock_temp]\
      unless (defined? @external_sensor).nil?

    @sm_relax_timer&.timer =\
      @config[:heating_sm_state_change_relaxation_time]
  end

  def valve_move_evaluation
    # Only perform real check if time is between 10:00 and 10:15 in the morning
    return unless\
    (((Time.now.to_i % (24 * 60 * 60)) + 60 * 60) > (10 * 60 * 60)) &&
    (((Time.now.to_i % (24 * 60 * 60)) + 60 * 60) < (10.25 * 60 * 60))

    # If moving already scheduled then return
    return if @moving_valves_required

    # If there is no logfile we need to move
    unless File.exist?(@config[:magnetic_valve_movement_logfile])
      @moving_valves_required = true
      @logger.info('No movement log file found - '\
        'Setting moving_valves_required to true for the first time')
      return
    end

    # If there is a logfile we need to read it and evaluate
    # movement need based on last log entry
    @move_logfile = File.new(@config[:magnetic_valve_movement_logfile], 'a+')
    @move_logfile.seek(0, IO::SEEK_SET)

    lastline = @move_logfile.readline until @move_logfile.eof

    seconds_between_move = @config[:magnetic_valve_movement_days] * 24 * 60 * 60

    # Move if moved later than the parameter read
    if lastline.to_i + seconds_between_move < Time.now.to_i &&
       # And we are just after 10 o'clock
       ((Time.now.to_i % (24 * 60 * 60)) + 60 * 60) > (10 * 60 * 60)
      @moving_valves_required = true
      @logger.info('Setting moving_valves_required to true')
    end
    @move_logfile.close
  end

  def do_magnetic_valve_movement
    @logger.info('Start moving valves')

    @radiator_pump.off
    @floor_pump.off
    @hydr_shift_pump.off
    @hot_water_pump.off

    # First move without water circulation
    relay_movement_thread = Thread.new do
      Thread.current[:name] = 'Relay movement thread'
      5.times do
        @buffer_heater.set_relays(:normal)
        sleep 10
        @buffer_heater.set_relays(:hw)
      end
    end

    5.times do
      @basement_floor_valve.open
      @basement_radiator_valve.open
      @living_floor_valve.open
      @upstairs_floor_valve.open
      sleep 1
      @basement_floor_valve.close
      @basement_radiator_valve.close
      @living_floor_valve.close
      @upstairs_floor_valve.close
      sleep 1
    end

    # Wait for relay movements to finish
    relay_movement_thread.join

    # Then move valves with water circulation
    5.times do
      @basement_floor_valve.open
      @basement_radiator_valve.open
      @living_floor_valve.open
      @upstairs_floor_valve.open

      @buffer_heater.set_relays(:normal)

      @radiator_pump.on
      @floor_pump.on
      @hydr_shift_pump.on

      sleep 10

      @basement_floor_valve.close
      @basement_radiator_valve.close
      @living_floor_valve.close
      @upstairs_floor_valve.close
      sleep 2

      @radiator_pump.off
      @floor_pump.off
      @hydr_shift_pump.off
    end

    @buffer_heater.set_relays(:hw)

    # Activate the hot water pump
    @hot_water_pump.on
    sleep 15
    @hot_water_pump.off

    sleep 2

    @buffer_heater.set_relays(:normal)

    @move_logfile = File.new(@config[:magnetic_valve_movement_logfile], 'a+')
    @move_logfile.write(Time.now.to_s)
    @move_logfile.write("\n")
    @move_logfile.write(Time.now.to_i.to_s)
    @move_logfile.write("\n")
    @move_logfile.close
    @logger.info('Moving valves finished')
  end

  # Perform app cycle logging
  def app_cycle_logging(power_needed)
    @logger.trace("Forward boiler temp: #{@forward_temp}")
    @logger.trace("Return temp: #{@return_temp}")
    @logger.trace("Upper buffer temp: #{@upper_buffer_temp}")
    @logger.trace("Heat return temp: #{@heat_return_temp}")
    @logger.trace("HW temp: #{@hw_thermostat.temp}")
    @logger.trace("Need power: #{power_needed}")
  end

  # Perform heating cycle logging
  def heating_cycle_logging(power_needed)
    return unless @logger_timer.expired?

    @logger_timer.reset

    @heating_logger.debug("LOGITEM BEGIN @ #{Time.now.asctime}")
    @heating_logger.debug("Active state: #{@heating_sm.current}")

    sth = ''.dup
    @state_history.each do |e|
      sth += ") => (#{e[:state]},#{e[:power]}," \
             "#{(Time.now.getlocal(0) - e[:timestamp].to_i).strftime('%T')} ago"
    end
    @heating_logger.debug("State and power_needed history : #{sth[5, 1000]})")
    @heating_logger.debug("Target output temp: #{@target_boiler_temp.round(2)}")
    @heating_logger.debug('Boiler forward temperature: '\
                          "#{@forward_temp.round(2)}")
    @heating_logger.debug("Boiler return temperature: #{@return_temp.round(2)}")
    @heating_logger.debug('Delta T on the Boiler: '\
                          "#{(@forward_temp - @return_temp).round(2)}")
    @heating_logger.debug('Heating forward temperature: '\
                          "#{@upper_buffer_temp.round(2)}")
    @heating_logger.debug('Heating return temperature: '\
                          "#{@heat_return_temp.round(2)}")
    @heating_logger.debug('Delta T on Buffer: '\
                          "#{(@upper_buffer_temp - @heat_return_temp).round(2)}")

    @heating_logger.debug("\nHW target/temperature: "\
                          "#{@hw_thermostat.threshold.round(2)}/"\
                          "#{@hw_thermostat.temp.round(2)}")

    @heating_logger.debug("\nExternal temperature: "\
                          "#{@floor_thermostat.temp.round(2)}")
    @heating_logger.debug("Mode thermostat status: #{@mode_thermostat.state}")
    @heating_logger.debug("Operating mode: #{@mode}")
    @heating_logger.debug("Need power: #{power_needed[:power]}")

    @heating_logger.debug("\nHW pump: #{@hot_water_pump.state}")
    @heating_logger.debug("Radiator pump: #{@radiator_pump.state}")
    @heating_logger.debug("Floor pump: #{@floor_pump.state}")
    @heating_logger.debug("Hydr shift pump: #{@hydr_shift_pump.state}")

    @heating_logger.debug("\nLiving target/temperature: "\
                          "#{@living_thermostat.threshold} / "\
                          "#{@living_thermostat.temp.round(2)}")
    @heating_logger.debug('Living thermostat state: '\
                          "#{@living_thermostat.state}")

    @heating_logger.debug("\nUpstairs target/temperature: "\
                          "#{@upstairs_thermostat.threshold} / "\
                          "#{@upstairs_thermostat.temp.round(2)}")
    @heating_logger.debug('Upstairs thermostat state: '\
                          "#{@upstairs_thermostat.state}")

    @heating_logger.debug('Living floor thermostat status: '\
                          "#{@floor_thermostat.state}")
    @heating_logger.debug("Living floor valve: #{@living_floor_valve.state}")
    @heating_logger.debug('Upstairs floor valve: '\
                          "#{@upstairs_floor_valve.state}")

    @heating_logger.debug("\nBasement target/temperature: "\
                          "#{@basement_thermostat.target} / "\
                          "#{@basement_thermostat.temp.round(2)}")
    @heating_logger.debug('Basement status/PWM value: '\
                          "#{@basement_thermostat.state} / "\
                          "#{(@basement_thermostat.value * 100).round(0)}%")
    @heating_logger.debug('Basement floor valve: '\
                          "#{@basement_floor_valve.state}")
    @heating_logger.debug('Basement thermostat status: '\
                          "#{@basement_thermostat.state}")
    @heating_logger.debug('Cold outside thermostat status/PWM value: '\
                          "#{@cold_outside_thermostat.state} / "\
                          "#{(@cold_outside_thermostat.value * 100).round(0)}%")
    @heating_logger.debug("\nBoiler relay: #{@heater_relay.state}")
    @heating_logger.debug("\nHP relay: #{@hp_relay.state}")
    @heating_logger.debug('Boiler required temperature: '\
                          "#{@heating_watertemp.temp_required.round(2)}")
    @heating_logger.debug("LOGITEM END\n")
  end

  # Walk through states to test the state machine
  def apply_test_control()
    Thread.pass

    sleep(0.5)

    begin
      @test_controls = YAML.load_file(Globals::TEST_CONTROL_FILE_PATH)
    rescue StandardError
      @logger.fatal('Cannot open config file: ' \
                        "#{Globals::TEST_CONTROL_FILE_PATH} Shutting down.")
      @config.shutdown_reason = Globals::FATAL_SHUTDOWN
    end

    @forward_temp = @test_controls[:boiler_temp]
    @return_temp = @test_controls[:return_temp]

    @hw_thermostat.test_update(@test_controls[:HW_temp])
    @living_thermostat.test_update(@test_controls[:living_temp])

    @upstairs_thermostat.test_update(@test_controls[:upstairs_temp])
    @basement_thermostat.test_update(@test_controls[:basement_temp])
    @basement_thermostat.target = @test_controls[:target_basement_temp]

    @floor_thermostat.test_update(@test_controls[:external_temp])

    @living_thermostat.threshold = @test_controls[:target_living_temp]
    @upstairs_thermostat.threshold = @test_controls[:target_upstairs_temp]

    @hw_thermostat.threshold = @test_controls[:target_HW_temp]
    @target_boiler_temp = @test_controls[:target_boiler_temp]

    @logger.debug("Living floor PWM thermostat value: #{@floor_thermostat.value}")
    @logger.debug("Living floor PWM thermostat state: #{@floor_thermostat.state}")
    @logger.debug("Power needed: #{determine_power_needed}")
    @test_cycle_cnt += 1
  end

  public

  def reload
    read_config
  end

  def shutdown
    # Turn off the heater
    @heating_sm.turnoff
    @logger.info('Shutdown complete. '\
                 "Shutdown reason: #{@config.shutdown_reason}")
    command = "rm -f #{@config.pidpath}"
    system(command)
  end
end
# of Class HeatingController
