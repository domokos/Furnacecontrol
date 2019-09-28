# frozen_string_literal: true

require '/usr/local/lib/boiler_controller/boiler_base'
require 'rubygems'

# Class of the heating controller
class HeatingController
  attr_reader :mixer_controller, :buffer_heater, :heating_watertemp
  attr_reader :radiator_pump, :floor_pump, :hw_watertemp, :heater_relay
  attr_reader :hydr_shift_pump, :hot_water_pump, :basement_floor_valve
  attr_reader :basement_radiator_valve
  attr_reader :living_floor_valve, :upstairs_floor_valve

  attr_reader :forward_temp, :hw_thermostat, :return_temp, :living_thermostat
  attr_reader :upstairs_thermostat, :basement_thermostat
  attr_reader :living_floor_thermostat, :mode_thermostat, :target_boiler_temp
  attr_reader :sm_relax_timer
  attr_reader :logger

  def initialize(logger, config)
    # Init instance variables
    @target_boiler_temp = 0.0
    @forward_temp = 0.0
    @return_temp = 0.0
    @test_cycle_cnt = 0
    @moving_valves_required = false
    @logger = logger
    @config = config

    read_config

    @logger_timer =
      Globals::TimerSec.new(@config[:logger_delay_whole_sec],
                            'Logging Delay Timer')

    create_pumps_and_sensors

    create_valueprocs

    create_devices

    create_sm_with_actions

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
    @hw_thermostat.set_threshold(@hw_watertemp_polycurve\
      .float_value(@living_floor_thermostat.temp))

    @logger.debug('Boiler controller initialized initial state '\
                      "set to: #{@heating_sm.current}, "\
                      "Initial mode set to: #{@mode}")
  end

  private

  # Create value procs/lambdas
  def create_valueprocs
    # Create the is_HW or valve movement proc for the floor PWM thermostats
    @is_hw_or_valve_proc = proc {
      determine_power_needed == :HW || @moving_valves_required == true
    }

    # Create the value proc for the basement thermostat. Lambda is used because
    # proc would also return the "return" command
    @basement_thermostat_valueproc = lambda { |sample_filter, target|
      error = target - sample_filter.value
      # Calculate compensation for water temperature drop
      multiplier = if @target_boiler_temp > 45
                     1
                   else
                     (45 - @target_boiler_temp) / 15 + 1
                   end
      return 0 if $low_floor_temp_mode

      value = (error + 0.9) / 5.0 * multiplier
      if value > 0.9
        value = 1
      elsif value < 0.2
        value = 0
      end
      return value
    }
  end

  def create_pumps_and_sensors
    # Create pumps
    @radiator_pump =
      BusDevice::Switch.new('Radiator pump',
                            'In the basement boiler room - Contact 4 on Main Panel',
                            @config[:main_controller_dev_addr],
                            @config[:radiator_pump_reg_addr], DRY_RUN)
    @floor_pump =
      BusDevice::Switch.new('Floor pump',
                            'In the basement boiler room - Contact 5 on Main Panel',
                            @config[:main_controller_dev_addr],
                            @config[:floor_pump_reg_addr], DRY_RUN)
    @hydr_shift_pump =
      BusDevice::Switch.new('Hydraulic shift pump',
                            'In the basement boiler room - Contact 6 on Main Panel',
                            @config[:main_controller_dev_addr],
                            @config[:hydr_shift_pump_reg_addr], DRY_RUN)
    @hot_water_pump =
      BusDevice::Switch.new('Hot water pump',
                            'In the basement boiler room - Contact 7 on Main Panel',
                            @config[:main_controller_dev_addr],
                            @config[:hot_water_pump_reg_addr], DRY_RUN)

    # Create temp sensors
    @mixer_sensor =
      BusDevice::TempSensor.new('Forward floor temperature',
                                'On the forward piping after the mixer valve',
                                @config[:mixer_controller_dev_addr],
                                @config[:mixer_fwd_sensor_reg_addr],
                                DRY_RUN, @config[:mixer_forward_mock_temp])
    @forward_sensor =
      BusDevice::TempSensor.new('Forward boiler temperature',
                                'On the forward piping of the boiler',
                                @config[:mixer_controller_dev_addr],
                                @config[:forward_sensor_reg_addr],
                                DRY_RUN, @config[:forward_mock_temp])
    @return_sensor =
      BusDevice::TempSensor.new('Return water temperature',
                                'On the return piping of the boiler',
                                @config[:mixer_controller_dev_addr],
                                @config[:return_sensor_reg_addr],
                                DRY_RUN, @config[:return_mock_temp])
    @upper_buffer_sensor =
      BusDevice::TempSensor.new('Upper Buffer temperature',
                                'Inside the buffer - upper section',
                                @config[:main_controller_dev_addr],
                                @config[:upper_buffer_sensor_reg_addr],
                                DRY_RUN, @config[:upper_buffer_mock_temp])
    @buffer_output_sensor =
      BusDevice::TempSensor.new('Buffer output temperature',
                                'On top of the buffer',
                                @config[:main_controller_dev_addr],
                                @config[:buffer_output_sensor_reg_addr],
                                DRY_RUN, @config[:buffer_output_mock_temp])
    @hw_sensor =
      BusDevice::TempSensor.new('Hot Water temperature',
                                'Inside the Hot water container main sensing tube',
                                @config[:main_controller_dev_addr],
                                @config[:hw_sensor_reg_addr],
                                DRY_RUN, @config[:HW_mock_temp])
    @living_sensor =
      BusDevice::TempSensor.new('Living room temperature',
                                'Temperature in the living room',
                                @config[:six_owbus_dev_addr],
                                @config[:living_sensor_reg_addr],
                                DRY_RUN, @config[:living_mock_temp])
    @upstairs_sensor =
      BusDevice::TempSensor.new('Upstairs temperature',
                                'Upstairs forest room',
                                @config[:six_owbus_dev_addr],
                                @config[:upstairs_sensor_reg_addr],
                                DRY_RUN, @config[:upstairs_mock_temp])
    @basement_sensor =
      BusDevice::TempSensor.new('Basement temperature',
                                'In the sauna rest area',
                                @config[:main_controller_dev_addr],
                                @config[:basement_sensor_reg_addr],
                                DRY_RUN, @config[:basement_mock_temp])
    @external_sensor =
      BusDevice::TempSensor.new('External temperature',
                                'On the northwestern external wall',
                                @config[:six_owbus_dev_addr],
                                @config[:external_sensor_reg_addr],
                                DRY_RUN, @config[:external_mock_temp])
  end

  # Create devices
  def create_devices
    # Create thermostats, with default threshold values and hysteresis values
    @living_thermostat =
      BoilerBase::SymmetricThermostat.new(@living_sensor, 0.3, 0.0, 15)
    @hw_thermostat =
      BoilerBase::ASymmetricThermostat.new(@hw_sensor, 2, 0, 0.0, 8)
    @living_floor_thermostat =
      BoilerBase::SymmetricThermostat.new(@external_sensor,
                                          @config[:living_floor_hysteresis],
                                          @config[:floor_heating_threshold], 30)
    @mode_thermostat =
      BoilerBase::SymmetricThermostat.new(@external_sensor,
                                          @config[:mode_hysteresis],
                                          @config[:mode_threshold], 50)
    @upstairs_thermostat =
      BoilerBase::SymmetricThermostat.new(@upstairs_sensor, 0.3, 5.0, 15)
    @basement_thermostat =
      BoilerBase::PwmThermostat.new(@basement_sensor, 30,
                                    @basement_thermostat_valueproc,
                                    @is_hw_or_valve_proc, 'Basement thermostat')

    # Create magnetic valves
    @basement_radiator_valve = \
      BusDevice::DelayedCloseMagneticValve\
      .new('Basement radiator valve',
           'Contact 8 on main board',
           @config[:main_controller_dev_addr],
           @config[:basement_radiator_valve_reg_addr],
           DRY_RUN)
    @basement_floor_valve = \
      BusDevice::DelayedCloseMagneticValve\
      .new('Basement floor valve',
           'Contact 9 on main board',
           @config[:main_controller_dev_addr],
           @config[:basement_floor_valve_reg_addr],
           DRY_RUN)
    @living_floor_valve = \
      BusDevice::DelayedCloseMagneticValve\
      .new('Living level floor valve',
           'In the living floor water distributor',
           @config[:six_owbus_dev_addr],
           @config[:living_floor_valve_reg_addr],
           DRY_RUN)
    @upstairs_floor_valve = \
      BusDevice::DelayedCloseMagneticValve\
      .new('Upstairs floor valve',
           'In the upstairs water distributor',
           @config[:six_owbus_dev_addr],
           @config[:upstairs_floor_valve_reg_addr],
           DRY_RUN)

    # Create buffer direction shift valves
    @hw_valve = \
      BusDevice::Switch\
      .new('Forward three-way valve',
           'After the boiler+buffer joint - Contact 2 on main board',
           @config[:main_controller_dev_addr],
           @config[:hw_valve_reg_addr], DRY_RUN)

    # Create heater relay switch
    @heater_relay = \
      BusDevice::Switch\
      .new('Heater relay', 'Heater contact on main panel',
           @config[:main_controller_dev_addr],
           @config[:heater_relay_reg_addr], DRY_RUN)

    # Create mixer pulsing switches
    @cw_switch = \
      BusDevice::PulseSwitch\
      .new('CW mixer switch', 'In the mixer controller box',
           @config[:mixer_controller_dev_addr],
           @config[:mixer_cw_reg_addr], DRY_RUN)
    @ccw_switch = \
      BusDevice::PulseSwitch\
      .new('CCW mixer switch', 'In the mixer controller box',
           @config[:mixer_controller_dev_addr],
           @config[:mixer_ccw_reg_addr], DRY_RUN)

    # Create water temp wipers
    @heating_watertemp = \
      BusDevice::HeatingWaterTemp\
      .new('Heating temp wiper',
           'Heating wiper contact on main panel',
           @config[:main_controller_dev_addr],
           @config[:heating_wiper_reg_addr], DRY_RUN)
    @hw_watertemp = \
      BusDevice::HWWaterTemp\
      .new('HW temp wiper',
           'HW wiper contact on main panel',
           @config[:main_controller_dev_addr],
           @config[:hw_wiper_reg_addr], DRY_RUN,
           @config[:hw_temp_shift])

    # Create the BufferHeat controller
    @buffer_heater = \
      BoilerBase::BufferHeat\
      .new(@forward_sensor, @upper_buffer_sensor,
           @buffer_output_sensor, @return_sensor,
           @hw_sensor, @hw_valve, @heater_relay, @hydr_shift_pump,
           @hot_water_pump, @hw_watertemp, @heating_watertemp)

    # Create the Mixer controller
    @mixer_controller = \
      BoilerBase::MixerControl\
      .new(@mixer_sensor, @cw_switch, @ccw_switch)
  end

  # Prefill sensors and thermostats to ensure smooth startup operation
  def prefill_sensors
    6.times do |i|
      @logger.info("Prefilling sensors. Round: #{i} of 6")
      read_sensors
      sleep 0.5
      $shutdown_reason != Globals::NO_SHUTDOWN && break
    end
  end

  # Define the activating actions of the statemachine
  def create_sm_with_actions
    # Create the heating state machine
    @heating_sm = BoilerBase::HeatingSM.new

    @sm_relax_timer = Globals::TimerSec.new(\
      @config[:heating_sm_state_change_relaxation_time],
      'Buffer SM state change relaxation timer'\
    )

    @heating_sm.target self

    # Log state transitions and arm the state change relaxation timer
    @heating_sm.on_before do |event|
      controller.logger.debug('Heating SM state change from '\
                        "#{event.from} to #{event.to}")
      controller.sm_relax_timer.reset
    end

    # Activation actions for Off satate
    @heating_sm.on_enter_off do |event|
      # Perform initialization on startup
      if event.name == :init
        controller.logger.debug('Heater SM initiaization')

        # Expire the timer to allow immediate state change
        controller.sm_relax_timer.expire

        # Regular turn off
      else
        controller.logger.debug('Turning off heating')
        # Stop the mixer controller
        controller.mixer_controller.stop_control

        # Signal heater to turn off
        controller.buffer_heater.set_mode(:off)

        # Wait before turning pumps off to make sure we do not lose circulation
        controller.logger.debug('Waiting shutdown delay')
        sleep @config[:shutdown_delay]
      end
      # Turn off all pumps
      controller.radiator_pump.off
      controller.floor_pump.off
      controller.hydr_shift_pump.off
      controller.hot_water_pump.off

      # Close all valves
      controller.basement_floor_valve.delayed_close
      controller.basement_radiator_valve.delayed_close
      controller.living_floor_valve.delayed_close
      controller.upstairs_floor_valve.delayed_close

      # Wait for the delayed closure to happen
      controller.logger.debug('Waiting for delayed closure valves to close')
      sleep 3
    end

    # Activation actions for Heating
    @heating_sm.on_enter_heating do
      controller.logger.debug('Activating "Heat" state')
      controller.mixer_controller.start_control
      # Do not control pumps or valves
    end

    # Activation actions for Post circulation heating
    @heating_sm.on_enter_postheating do
      controller.logger.debug('Activating "Postheat" state')

      # Signal heater to turn off
      controller.buffer_heater.set_mode(:off)

      # Stop the mixer controller
      controller.mixer_controller.stop_control

      # Set the buffer for direct connection
      controller.buffer_heater.set_relays(:normal)

      # Hydr shift pump on
      controller.hydr_shift_pump.on

      # All other pumps off
      controller.floor_pump.off
      controller.hot_water_pump.off
      controller.radiator_pump.off

      # All valves closed
      controller.basement_radiator_valve.delayed_close
      controller.basement_floor_valve.delayed_close
      controller.living_floor_valve.delayed_close
      controller.upstairs_floor_valve.delayed_close

      # Wait for the delayed closure to happen
      controller.logger.debug('Waiting for delayed closure valves to close')
      sleep 3
    end

    # Activation actions for Post circulation heating
    @heating_sm.on_enter_posthwing do
      controller.logger.debug('Activating \"PostHW\" state')

      # Signal heater to turn off
      controller.buffer_heater.set_mode(:off)

      # Set the buffer for direct connection
      controller.buffer_heater.set_relays(:HW)

      # Stop the mixer controller
      controller.mixer_controller.stop_control

      controller.hot_water_pump.on
      # Wait before turning pumps off to make sure we do not lose circulation
      sleep @config[:circulation_maintenance_delay]

      # Only HW pump on
      controller.radiator_pump.off
      controller.floor_pump.off
      controller.hydr_shift_pump.off

      # All valves are closed
      controller.basement_floor_valve.delayed_close
      controller.basement_radiator_valve.delayed_close
      controller.living_floor_valve.delayed_close
      controller.upstairs_floor_valve.delayed_close

      # Wait for the delayed closure to happen
      controller.logger.debug('Waiting for delayed closure valves to close')
      sleep 3
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
          @logger.debug('Need power is: NONE coming from normal heating')
          # Turn off the heater
          @heating_sm.turnoff
        else
          raise 'Unexpected heater state in '\
                "evaluate_state_change: #{buffer_heater.state}"
        end
      end

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
    @living_thermostat.update
    @upstairs_thermostat.update
    @basement_thermostat.update
    @living_floor_thermostat.update
    @mode_thermostat.update
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
    while $shutdown_reason == Globals::NO_SHUTDOWN

      @logger.trace('Main boiler loop cycle start')

      # Sleep to spare processor time
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
    @living_thermostat.set_threshold(@config[:target_living_temp])
    @upstairs_thermostat.set_threshold(@config[:target_upstairs_temp])
    @basement_thermostat.set_target(@config[:target_basement_temp])
    @mode_thermostat.set_threshold(@config[:mode_threshold])
    @mode_thermostat.hysteresis = @config[:mode_hysteresis]

    @living_floor_thermostat.set_threshold(@config[:floor_heating_threshold])

    # Update watertemp Polycurves
    @heating_watertemp_polycurve.load(@config[:heating_watertemp_polycurve])
    @floor_watertemp_polycurve.load(@config[:floor_watertemp_polycurve])
    @hw_watertemp_polycurve.load(@config[:HW_watertemp_polycurve])

    @mode = @mode_thermostat.on? ? :mode_Heat_HW : :mode_HW

    case power_needed[:power]
    when :HW
      # Leave the heating wiper where it is.
      # Set HW target temp only when in HW mode to avoid
      # sneak climbing of HW target
      @hw_thermostat.set_threshold(@hw_watertemp_polycurve\
        .float_value(@living_floor_thermostat.temp))

    when :RAD
      @target_boiler_temp = @heating_watertemp_polycurve\
                            .float_value(@living_floor_thermostat.temp)

    when :RADFLOOR
      # Set target to the higher value
      @target_boiler_temp =
        if @heating_watertemp_polycurve.float_value(@living_floor_thermostat.temp) >
           @floor_watertemp_polycurve.float_value(@living_floor_thermostat.temp)
          @heating_watertemp_polycurve.float_value(@living_floor_thermostat.temp)
        else
          @floor_watertemp_polycurve.float_value(@living_floor_thermostat.temp)
        end

      @mixer_controller.set_target_temp(@floor_watertemp_polycurve\
        .float_value(@living_floor_thermostat.temp))

    when :FLOOR
      @target_boiler_temp = @floor_watertemp_polycurve\
                            .float_value(@living_floor_thermostat.temp)
      @mixer_controller.set_target_temp(@floor_watertemp_polycurve\
        .float_value(@living_floor_thermostat.temp))

    when :NONE
      @target_boiler_temp = 7.0

    end
    # End of determine_targets
  end

  # Control heating
  def control_heat(prev_power_needed,power_needed)
    changed = ((prev_power_needed[:power] != power_needed[:power]) || \
    (prev_power_needed[:state] != power_needed[:state]))

    case power_needed[:power]
    when :HW
      return unless changed

      # Set mode of the heater
      @logger.debug('Setting heater mode to HW')
      @buffer_heater.set_mode(:HW)
      @mixer_controller.pause
    when :RAD, :RADFLOOR, :FLOOR
      # Set mode and required water temperature of the boiler
      @logger.trace("Setting heater target temp to: #{@target_boiler_temp}")
      @buffer_heater.set_target(@target_boiler_temp,\
                                power_needed[:power] != :RAD)
      if power_needed[:power] == :FLOOR && changed
        @logger.debug('Setting heater mode to :floorheat')
        @buffer_heater.set_mode(:floorheat)
      elsif changed
        @logger.debug('Setting heater mode to :radheat')
        @buffer_heater.set_mode(:radheat)
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

  # This function controls valves, pumps and heat during heating by evaluating the required power
  def control_pumps_valves_for_heating(prev_power_needed,power_needed)
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

        # Radiator pump on
        @radiator_pump.on
        # Floor heating off
        @floor_pump.off
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
      if @living_floor_thermostat.on?
        @living_floor_valve.open
        @upstairs_floor_valve.open
      else
        @living_floor_valve.delayed_close
        @upstairs_floor_valve.delayed_close
      end

      if changed
        @logger.info('Setting valves and pumps for RADFLOOR')

        # Floor heating on
        @floor_pump.on
        # Radiator pump on
        @radiator_pump.on
      end
    when :FLOOR
      # decide on basement valve based on basement temperature
      if @basement_thermostat.on?
        @basement_floor_valve.open
      else
        @basement_floor_valve.delayed_close
      end

      # decide on floor valves based on external temperature
      if @living_floor_thermostat.on?
        @living_floor_valve.open
        @upstairs_floor_valve.open
      else
        @living_floor_valve.delayed_close
        @upstairs_floor_valve.delayed_close
      end

      if changed
        @logger.info('Setting valves and pumps for FLOOR')
        @basement_radiator_valve.delayed_close

        # Floor heating on
        @floor_pump.on
        @radiator_pump.off
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
          @living_thermostat.on?) && \
          @living_floor_thermostat.off? && \
          @basement_thermostat.off?
      # Power needed for heating
      :RAD
    elsif @mode == :mode_Heat_HW && (@upstairs_thermostat.on? || \
          @living_thermostat.on?) && \
          (@living_floor_thermostat.on? || \
          @basement_thermostat.on?)
      # Power needed for heating and floor heating
      :RADFLOOR
    elsif @mode == :mode_Heat_HW && (@living_floor_thermostat.on? || \
          @basement_thermostat.on?)
      # Power needed for floor heating only
      :FLOOR
    else
      # No power needed
      :NONE
    end
  end

  def read_config
    Globals.read_global_config

    $config_mutex.synchronize do
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

      @sm_relax_timer&.set_timer\
        (@config[:heating_sm_state_change_relaxation_time])
    end
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

    # If there is a logfile we need to read it and evaluate movement need based on last log entry
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
        @buffer_heater.set_relays(:HW)
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
    end

    @buffer_heater.set_relays(:normal)

    # Activate the hot water pump
    @hot_water_pump.on
    sleep 15
    @hot_water_pump.off

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
    @logger.trace("HW temp: #{@hw_thermostat.temp}")
    @logger.trace("Need power: #{power_needed}")
  end

  # Perform heating cycle logging
  def heating_cycle_logging(power_needed)
    return unless @logger_timer.expired?

    @logger_timer.reset

    $heating_logger.debug("LOGITEM BEGIN @ #{Time.now.asctime}")
    $heating_logger.debug("Active state: #{@heating_sm.current}")

    sth = ''.dup
    @state_history.each do |e|
      sth += ") => (#{e[:state]},#{e[:power]}," + \
             (Time.now.getlocal(0) - e[:timestamp].to_i).strftime('%T') + ' ago'
    end
    $heating_logger.debug("State and power_needed history : #{sth[5, 1000]})")
    $heating_logger.debug("Forward temperature: #{@forward_temp.round(2)}")
    $heating_logger.debug("Return water temperature: #{@return_temp.round(2)}")
    $heating_logger.debug("Delta T on the Boiler: #{(@forward_temp - @return_temp).round(2)}")
    $heating_logger.debug("Target boiler temp: #{@target_boiler_temp.round(2)}")

    $heating_logger.debug("\nHW target/temperature: #{@hw_thermostat.threshold.round(2)}/"\
                          "#{@hw_thermostat.temp.round(2)}")

    $heating_logger.debug("\nExternal temperature: "\
                          "#{@living_floor_thermostat.temp.round(2)}")
    $heating_logger.debug("Mode thermostat status: #{@mode_thermostat.state}")
    $heating_logger.debug("Operating mode: #{@mode}")
    $heating_logger.debug("Need power: #{power_needed[:power]}")

    $heating_logger.debug("\nHW pump: #{@hot_water_pump.state}")
    $heating_logger.debug("Radiator pump: #{@radiator_pump.state}")
    $heating_logger.debug("Floor pump: #{@floor_pump.state}")
    $heating_logger.debug("Hydr shift pump: #{@hydr_shift_pump.state}")

    $heating_logger.debug("\nLiving target/temperature: #{@living_thermostat.threshold} / "\
                          "#{@living_thermostat.temp.round(2)}")
    $heating_logger.debug("Living thermostat state: #{@living_thermostat.state}")

    $heating_logger.debug("\nUpstairs target/temperature: #{@upstairs_thermostat.threshold} / "\
                          "#{@upstairs_thermostat.temp.round(2)}")
    $heating_logger.debug("Upstairs thermostat state: #{@upstairs_thermostat.state}")

    $heating_logger.debug("Living floor thermostat status: #{@living_floor_thermostat.state}")
    $heating_logger.debug("Living floor valve: #{@living_floor_valve.state}")
    $heating_logger.debug("Upstairs floor valve: #{@upstairs_floor_valve.state}")

    $heating_logger.debug("\nBasement target/temperature: #{@basement_thermostat.target} / "\
                          "#{@basement_thermostat.temp.round(2)}")
    $heating_logger.debug("Basement PWM value: #{(@basement_thermostat.value * \
                          100).round(0)}%")
    $heating_logger.debug("Basement floor valve: #{@basement_floor_valve.state}")
    $heating_logger.debug('Basement thermostat status: '\
                          "#{@basement_thermostat.state}")

    $heating_logger.debug("\nBoiler relay: #{@heater_relay.state}")
    $heating_logger.debug('Boiler required temperature: '\
                          "#{@heating_watertemp.temp_required.round(2)}")
    $heating_logger.debug("LOGITEM END\n")
  end

  # Walk through states to test the state machine
  def apply_test_control()
    Thread.pass

    sleep(0.5)

    begin
      @test_controls = YAML.load_file(Globals::TEST_CONTROL_FILE_PATH)
    rescue StandardError
      @logger.fatal('Cannot open config file: ' + \
                        Globals::TEST_CONTROL_FILE_PATH + ' Shutting down.')
      $shutdown_reason = Globals::FATAL_SHUTDOWN
    end

    @forward_temp = @test_controls[:boiler_temp]
    @return_temp = @test_controls[:return_temp]

    @hw_thermostat.test_update(@test_controls[:HW_temp])
    @living_thermostat.test_update(@test_controls[:living_temp])

    @upstairs_thermostat.test_update(@test_controls[:upstairs_temp])
    @basement_thermostat.test_update(@test_controls[:basement_temp])
    @basement_thermostat.set_target(@test_controls[:target_basement_temp])

    @living_floor_thermostat.test_update(@test_controls[:external_temp])

    @living_thermostat.set_threshold(@test_controls[:target_living_temp])
    @upstairs_thermostat.set_threshold(@test_controls[:target_upstairs_temp])

    @hw_thermostat.set_threshold(@test_controls[:target_HW_temp])
    @target_boiler_temp = @test_controls[:target_boiler_temp]

    @logger.debug("Living floor PWM thermostat value: #{@living_floor_thermostat.value}")
    @logger.debug("Living floor PWM thermostat state: #{@living_floor_thermostat.state}")
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
    @logger.info('Shutdown complete. Shutdown reason: ' + $shutdown_reason)
    command = 'rm -f ' + $pidpath
    system(command)
  end
end
# of Class HeatingController
