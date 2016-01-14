#!/usr/local/rvm/rubies/ruby-2.1.5/bin/ruby
# Boiler control softvare
# Ver 1 - 12 Dec 2014
#   - Initial coding work for RS485 bus based communication for the condensing boiler
#

require "/usr/local/lib/boiler_controller/boiler_base"
require "rubygems"
require "robustthread"
require "yaml"

Thread.abort_on_exception=true

$stdout.sync = true

$app_logger.level = Globals::BoilerLogger::INFO
$heating_logger.level = Logger::INFO

DRY_RUN = false
$shutdown_reason = Globals::NO_SHUTDOWN
$low_floor_temp_mode = false

Signal.trap("TTIN") do
  puts "---------\n"
  Thread.list.each do |thread|
    puts "Thread name: "+thread[:name].to_s+" ID: #{thread.object_id.to_s(36)}"
    puts thread.backtrace.join("\n")
    puts "---------\n"
  end
  puts "---------\n"
end

Signal.trap("USR1") do
  $app_logger.level = Globals::BoilerLogger::INFO
  $heating_logger.level = Logger::DEBUG
end

Signal.trap("USR2") do
  $app_logger.level = Globals::BoilerLogger::INFO
  $heating_logger.level = Logger::INFO
end

Signal.trap("URG") do
  $app_logger.level = Globals::BoilerLogger::DEBUG
  $heating_logger.level = Logger::DEBUG
end

class Heating_controller

  attr_reader :mixer_controller, :buffer_heater, :heating_watertemp, :HW_watertemp, :heater_relay
  attr_reader :radiator_pump, :floor_pump,  :hydr_shift_pump, :hot_water_pump
  attr_reader :basement_floor_valve, :basement_radiator_valve, :living_floor_valve, :upstairs_floor_valve
  def initialize(initial_state,initial_mode)

    # Init instance variables
    @target_boiler_temp = 0.0
    @forward_temp = 0.0
    @return_temp = 0.0
    @HW_temp = 0.0
    @test_cycle_cnt = 0
    @moving_valves_required = false

    read_config

    @logger_timer = Globals::TimerSec.new($config[:logger_delay_whole_sec],"Logging Delay Timer")

    # Create pumps
    @radiator_pump = BusDevice::Switch.new("Radiator pump", "In the basement boiler room - Contact 4 on Main Panel",
    $config[:main_controller_dev_addr], $config[:radiator_pump_reg_addr], DRY_RUN)
    @floor_pump = BusDevice::Switch.new("Floor pump", "In the basement boiler room - Contact 5 on Main Panel",
    $config[:main_controller_dev_addr], $config[:floor_pump_reg_addr], DRY_RUN)
    @hydr_shift_pump = BusDevice::Switch.new("Hydraulic shift pump", "In the basement boiler room - Contact 6 on Main Panel",
    $config[:main_controller_dev_addr], $config[:hydr_shift_pump_reg_addr], DRY_RUN)
    @hot_water_pump = BusDevice::Switch.new("Hot water pump", "In the basement boiler room - Contact 7 on Main Panel",
    $config[:main_controller_dev_addr], $config[:hot_water_pump_reg_addr], DRY_RUN)

    # Create temp sensors
    @mixer_sensor = BusDevice::TempSensor.new("Forward floor temperature", "On the forward piping after the mixer valve",
    $config[:mixer_controller_dev_addr], $config[:mixer_fwd_sensor_reg_addr], DRY_RUN, $config[:mixer_forward_mock_temp])
    @forward_sensor = BusDevice::TempSensor.new("Forward boiler temperature", "On the forward piping of the boiler",
    $config[:mixer_controller_dev_addr], $config[:forward_sensor_reg_addr], DRY_RUN, $config[:forward_mock_temp])
    @return_sensor = BusDevice::TempSensor.new("Return water temperature", "On the return piping of the boiler",
    $config[:mixer_controller_dev_addr], $config[:return_sensor_reg_addr], DRY_RUN, $config[:return_mock_temp])
    @upper_buffer_sensor = BusDevice::TempSensor.new("Upper Buffer temperature", "Inside the buffer - upper section",
    $config[:main_controller_dev_addr], $config[:upper_buffer_sensor_reg_addr], DRY_RUN, $config[:upper_buffer_mock_temp])
    @lower_buffer_sensor = BusDevice::TempSensor.new("Lower Buffer temperature", "Inside the buffer - lower section",
    $config[:main_controller_dev_addr], $config[:lower_buffer_sensor_reg_addr], DRY_RUN, $config[:lower_buffer_mock_temp])
    @HW_sensor = BusDevice::TempSensor.new("Hot Water temperature","Inside the Hot water container main sensing tube",
    $config[:main_controller_dev_addr], $config[:hw_sensor_reg_addr], DRY_RUN, $config[:HW_mock_temp])

    @living_sensor = BusDevice::TempSensor.new("Living room temperature","Temperature in the living room",
    $config[:six_owbus_dev_addr], $config[:living_sensor_reg_addr], DRY_RUN, $config[:living_mock_temp])
    @upstairs_sensor = BusDevice::TempSensor.new("Upstairs temperature","Upstairs forest room",
    $config[:six_owbus_dev_addr], $config[:upstairs_sensor_reg_addr], DRY_RUN, $config[:upstairs_mock_temp])
    @basement_sensor = BusDevice::TempSensor.new("Basement temperature","In the sauna rest area",
    $config[:main_controller_dev_addr], $config[:basement_sensor_reg_addr], DRY_RUN, $config[:basement_mock_temp])
    @external_sensor = BusDevice::TempSensor.new("External temperature","On the northwestern external wall",
    $config[:six_owbus_dev_addr], $config[:external_sensor_reg_addr], DRY_RUN, $config[:external_mock_temp])

    # Create the is_HW or valve movement proc for the floor PWM thermostats
    @is_HW_or_valve_proc = proc {
      determine_power_needed == "HW" or @moving_valves_required == true
    }

    # Create the value proc for the basement thermostat. Lambda is used because proc would also return the "return" command
    @basement_thermostat_valueproc = lambda { |sample_filter, target|
      error = target - sample_filter.value
      if $low_floor_temp_mode
        return 0
      else
        value = (error+0.9)/5.0
        if (value > 1.0)
          return 1
        elsif (value < 0.2)
          return 0
        else
          return value
        end
      end
    }

    # Create thermostats, with default threshold values and hysteresis values
    @living_thermostat = BoilerBase::Symmetric_thermostat.new(@living_sensor,0.3,0.0,15)
    @HW_thermostat = BoilerBase::Asymmetric_thermostat.new(@HW_sensor,2,0,0.0,8)
    @living_floor_thermostat = BoilerBase::Symmetric_thermostat.new(@external_sensor,2,15.0,30)
    @mode_thermostat = BoilerBase::Symmetric_thermostat.new(@external_sensor,0.9,5.0,50)
    @upstairs_thermostat = BoilerBase::Symmetric_thermostat.new(@upstairs_sensor,0.3,5.0,15)
    @basement_thermostat = BoilerBase::PwmThermostat.new(@basement_sensor,30,@basement_thermostat_valueproc,@is_HW_or_valve_proc,"Basement thermostat")

    # Create magnetic valves
    @basement_radiator_valve = BusDevice::DelayedCloseMagneticValve.new("Basement radiator valve","Contact 8 on main board",
    $config[:main_controller_dev_addr], $config[:basement_radiator_valve_reg_addr], DRY_RUN)
    @basement_floor_valve = BusDevice::DelayedCloseMagneticValve.new("Basement floor valve","Contact 9 on main board",
    $config[:main_controller_dev_addr], $config[:basement_floor_valve_reg_addr], DRY_RUN)
    @living_floor_valve = BusDevice::DelayedCloseMagneticValve.new("Living level floor valve","In the living floor water distributor",
    $config[:six_owbus_dev_addr], $config[:living_floor_valve_reg_addr], DRY_RUN)
    @upstairs_floor_valve = BusDevice::DelayedCloseMagneticValve.new("Upstairs floor valve","In the upstairs water distributor",
    $config[:six_owbus_dev_addr], $config[:upstairs_floor_valve_reg_addr], DRY_RUN)

    # Create buffer direction shift valves
    @forward_valve = BusDevice::Switch.new("Forward three-way valve","After the boiler+buffer joint - Contact 2 on main board",
    $config[:main_controller_dev_addr], $config[:forward_valve_reg_addr], DRY_RUN)
    @return_valve = BusDevice::Switch.new("Return valve","Before the buffer cold entry point - Contact 3 on main board",
    $config[:main_controller_dev_addr], $config[:return_valve_reg_addr], DRY_RUN)
    @bypass_valve = BusDevice::Switch.new("Hydraulic shifter bypass valve","After the hydraulic shift - Contact 4 on mixer controller",
    $config[:mixer_controller_dev_addr], $config[:mixer_hydr_shift_bypass_valve_reg_addr], DRY_RUN)

    # Create heater relay switch
    @heater_relay = BusDevice::Switch.new("Heater relay","Heater contact on main panel",
    $config[:main_controller_dev_addr], $config[:heater_relay_reg_addr], DRY_RUN)

    #Create mixer pulsing switches
    @cw_switch = BusDevice::PulseSwitch.new("CW mixer switch","In the mixer controller box",
    $config[:mixer_controller_dev_addr], $config[:mixer_cw_reg_addr], DRY_RUN)
    @ccw_switch = BusDevice::PulseSwitch.new("CCW mixer switch","In the mixer controller box",
    $config[:mixer_controller_dev_addr], $config[:mixer_ccw_reg_addr], DRY_RUN)

    # Create water temp wipers
    @heating_watertemp = BusDevice::HeatingWaterTemp.new("Heating temp wiper", "Heating wiper contact on main panel",
    $config[:main_controller_dev_addr], $config[:heating_wiper_reg_addr], DRY_RUN)
    @HW_watertemp = BusDevice::HWWaterTemp.new("HW temp wiper", "HW wiper contact on main panel",
    $config[:main_controller_dev_addr], $config[:hw_wiper_reg_addr], DRY_RUN, $config[:hw_temp_shift])

    #Create the BufferHeat controller
    @buffer_heater = BoilerBase::BufferHeat.new(@forward_sensor, @upper_buffer_sensor, @lower_buffer_sensor, @return_sensor,
    @HW_sensor, @forward_valve, @return_valve, @bypass_valve, @heater_relay, @hydr_shift_pump, @hot_water_pump,
    @HW_watertemp, @heating_watertemp)

    #Create the Mixer controller
    $app_logger.debug("Creating Mixer controller")

    @mixer_controller = BoilerBase::Mixer_control.new(@mixer_sensor,@cw_switch,@ccw_switch)
    $app_logger.debug("Mixer controller created")

    # Create the heating state machine
    @heating_sm = BoilerBase::HeatingSM.new
    @heating_sm.target self

    # Define the activating actions of the statemachine
    # Activation actions for Off satate
    @heating_sm.on_enter_off do |event|

      # Perform initialization on startup
      if event.from == :none
        $app_logger.debug("Heater SM initiaization")

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
        sleep 3

        # Regular turn off
      else
        $app_logger.debug("Turning off heating")
        # Stop the mixer controller
        controller.mixer_controller.stop_control

        # Signal heater to turn off
        controller.buffer_heater.set_mode(:off)

        # Wait before turning pumps off to make sure we do not lose circulation
        $app_logger.debug("Waiting shutdown delay")
        sleep $config[:shutdown_delay]

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
        $app_logger.debug("Waiting for delayed closure valves to close")
        sleep 3
      end
    end

    # Activation actions for Heating
    @heating_sm.on_enter_heating do |event|
      $app_logger.debug("Activating \"Heat\" state")
      # Do not control pumps or valves
    end

    # Activation actions for Post circulation heating
    @heating_sm.on_enter_postheating do |event|
      $app_logger.debug("Activating \"Postheat\" state")

      # Signal heater to turn off
      controller.buffer_heater.set_mode(:off)

      # Stop the mixer controller
      controller.mixer_controller.stop_control

      # Set the buffer for direct connection
      controller.buffer_heater.set_relays(:hydr_shifted)

      # All radiator valves open
      controller.basement_radiator_valve.open

      # Radiator pumps on
      controller.hydr_shift_pump.on
      controller.radiator_pump.on

      # Wait before turning pumps off to make sure we do not lose circulation
      sleep $config[:circulation_maintenance_delay]

      controller.floor_pump.off
      controller.hot_water_pump.off

      # All floor valves closed
      controller.basement_floor_valve.delayed_close
      controller.living_floor_valve.delayed_close
      controller.upstairs_floor_valve.delayed_close
    end

    # Activation actions for Post circulation heating
    @heating_sm.on_enter_posthwing do |event|
      $app_logger.debug("Activating \"PostHW\" state")

      # Signal heater to turn off
      controller.buffer_heater.set_mode(:off)

      # Set the buffer for direct connection
      controller.buffer_heater.set_relays(:hydr_shifted)

      # Stop the mixer controller
      controller.mixer_controller.stop_control

      controller.hot_water_pump.on
      # Wait before turning pumps off to make sure we do not lose circulation
      sleep $config[:circulation_maintenance_delay]

      # Only HW pump on
      controller.radiator_pump.off
      controller.floor_pump.off
      controller.hydr_shift_pump.off

      # All valves are closed
      controller.basement_floor_valve.delayed_close
      controller.basement_radiator_valve.delayed_close
      controller.living_floor_valve.delayed_close
      controller.upstairs_floor_valve.delayed_close
    end

    # Set the initial state
    @heating_sm.init

    # Set the initial mode
    if initial_mode == :Off
      @mode = :mode_Off
    elsif initial_mode == :HW
      @mode = :mode_HW
    elsif initial_mode == :Heat
      @mode = :mode_Heat_HW
    else
      $app_logger.fatal("Illegal initial mode. Aborting.")
      exit
    end

    # Create watertemp Polycurves
    @heating_watertemp_polycurve = Globals::Polycurve.new($config[:heating_watertemp_polycurve])
    @floor_watertemp_polycurve = Globals::Polycurve.new($config[:floor_watertemp_polycurve])

    # Prefill sensors and thermostats to ensure smooth startup operation
    for i in 1..6 do
      $app_logger.debug("Prefilling sensors. Round: "+i.to_s+" of 6")
      read_sensors
      temp_power_needed = {:state=>@heating_sm.current,:power=>determine_power_needed}
      determine_targets(temp_power_needed,temp_power_needed)
      sleep 0.5
      break if $shutdown_reason != Globals::NO_SHUTDOWN
    end

    $app_logger.debug("Boiler controller initialized initial state set to: "+@heating_sm.current.to_s+", Initial mode set to: "+@mode.to_s)

  end

  # The function evaluating states and performing necessary
  # transitions basd on the current value of sensors
  def evaluate_state_change(prev_power_needed,power_needed)
    case @heating_sm.current
    # The evaluation of the off state
    when :off
      # Evaluating Off state:
      # If need power then -> heating
      # If forward temp increases and forward temp above HW temp + 7 C in HW mode then -> posthwing
      # If forward temp increases and forward temp above HW temp + 7 C not in HW mode then -> postheating
      # Else: Stay in off state

      if power_needed[:power] != :NONE
        $app_logger.debug("Need power is : "+power_needed[:power].to_s)
        @heating_sm.turnon
      else
        $app_logger.trace("Decision: No power requirement - not changing state")
      end

    when :heating
      # Evaluating Heat state:
      # Control valves and pumps based on measured temperatures
      # Control boiler wipers to maintain target boiler temperature
      # If not need power anymore then -> postheating or posthw based on operating mode

      if power_needed[:power] == :NONE and @mode == :mode_HW
        $app_logger.debug("Need power is: NONE")
        # Turn off the heater
        @heating_sm.posthw
      elsif power_needed[:power] == :NONE
        $app_logger.debug("Need power is: NONE")
        # Turn off the heater
        @heating_sm.postheat
      end

    when :postheating
      # Evaluating postheating state:
      # If Delta T on the Furnace drops below 5 C then -> off
      # If need power is not false then -> heat
      # If Delta T on the Furnace drops below 5 C then -> off

      if @forward_temp - @return_temp < 5.0
        $app_logger.debug("Delta T on the Furnace dropped below 5 C")
        # Turn off the heater
        @heating_sm.turnoff
        # If need power then -> Heat
      elsif power_needed[:power] != :NONE
        $app_logger.debug("Need power is "+power_needed[:power].to_s)
        @heating_sm.turnon
      end

    when :posthwing
      # Evaluating PostHW state:
      # If Delta T on the Furnace drops below 5 C then -> Off
      # If Furnace temp below HW temp + 4 C then -> Off
      # If need power is not false then -> Heat
      # If Delta T on the Furnace drops below 5 C then -> Off

      if @forward_temp - @return_temp < 5.0
        $app_logger.debug("Delta T on the Furnace dropped below 5 C")
        # Turn off the heater
        @heating_sm.turnoff
        # If Furnace temp below HW temp + 4 C then -> Off
      elsif @forward_temp < @HW_thermostat.temp + 4
        $app_logger.debug("Furnace temp below HW temp + 4 C")
        # Turn off the heater
        @heating_sm.turnoff
        # If need power then -> Heat
      elsif power_needed[:power] != :NONE
        $app_logger.debug("Need power is "+power_needed[:power].to_s)
        # Turn off the heater
        @heating_sm.turnoff
      end
    end
  end

  # Read the temperature sensors
  def read_sensors
    @forward_temp = @forward_sensor.temp
    @HW_thermostat.update
    @return_temp = @return_sensor.temp
    @living_thermostat.update
    @upstairs_thermostat.update
    @basement_thermostat.update
    @living_floor_thermostat.update
    @mode_thermostat.update
  end

  # The main loop of the controller
  def operate
    @state_history = Array.new(4,{:state=>@heating_sm.current,:power=>determine_power_needed,:timestamp=>Time.now.getlocal(0)})

    prev_power_needed = {:state=>:Off,:power=>:NONE,:timestamp=>Time.now.getlocal(0)}
    power_needed = {:state=>@heating_sm.current,:power=>determine_power_needed,:timestamp=>Time.now.getlocal(0)}

    # Do the main loop until shutdown is requested
    while($shutdown_reason == Globals::NO_SHUTDOWN) do

      $app_logger.trace("Main boiler loop cycle start")

      # Sleep to spare processor time
      sleep $config[:main_loop_delay]

      # Apply the test conrol if in dry run
      apply_test_control if DRY_RUN

      # Determinde power needed - its cahange
      # and real heating tartgets if not in dry run
      if !DRY_RUN
        read_sensors
        temp_power_needed = {:state=>@heating_sm.current,:power=>determine_power_needed,:timestamp=>Time.now.getlocal(0)}
        if temp_power_needed[:state] != power_needed[:state] or temp_power_needed[:power] != power_needed[:power]
          prev_power_needed = power_needed
          power_needed = temp_power_needed

          # Record state history for the last 4 states
          @state_history.shift
          @state_history.push(power_needed)
        else
          prev_power_needed = power_needed
        end
        determine_targets(prev_power_needed,power_needed)
      end

      # Call the state machine state transition decision method
      evaluate_state_change(prev_power_needed,power_needed)

      # Conrtol heating when in heating state
      if @heating_sm.current == :heating
        # Control heat
        control_heat(prev_power_needed,power_needed)

        # Control valves and pumps
        control_pumps_valves_for_heating(prev_power_needed,power_needed)
      end

      # Perform cycle logging
      app_cycle_logging(power_needed)
      heating_cycle_logging(power_needed)

      # Evaluate if moving valves is required and
      # schedule a movement cycle if needed
      valve_move_evaluation

      # If magnetic valve movement is required then carry out moving process
      # and reset movement required flag
      if @moving_valves_required and @heating_sm.current == :off
        do_magnetic_valve_movement
        @moving_valves_required = false
      end
    end
    shutdown
  end

  # Read the target temperatures, determine targets and operating mode
  def determine_targets(prev_power_needed,power_needed)
    # Read the config file
    read_config

    # Update thermostat targets
    @living_thermostat.set_threshold($config[:target_living_temp])
    @upstairs_thermostat.set_threshold($config[:target_upstairs_temp])
    @basement_thermostat.set_target($config[:target_basement_temp])
    @mode_thermostat.set_threshold($config[:mode_threshold])
    @HW_thermostat.set_threshold($config[:target_HW_temp])
    @living_floor_thermostat.set_threshold($config[:floor_heating_threshold])

    # Update watertemp Polycurves
    @heating_watertemp_polycurve.load($config[:heating_watertemp_polycurve])
    @floor_watertemp_polycurve.load($config[:floor_watertemp_polycurve])

    if @mode_thermostat.is_on?
      @heating_sm.current != :heating and @mode = :mode_Heat_HW
    else
      @heating_sm.current != :heating and @mode = :mode_HW
    end

    case power_needed[:power]
    when :HW
      # Do nothing - just leave the heating wiper where it is.

    when :RAD, :RADFLOOR
      @target_boiler_temp =
      @heating_watertemp_polycurve.float_value(@living_floor_thermostat.temp) > @floor_watertemp_polycurve.float_value(@living_floor_thermostat.temp) ? \
      @heating_watertemp_polycurve.float_value(@living_floor_thermostat.temp) : \
      @floor_watertemp_polycurve.float_value(@living_floor_thermostat.temp)

    when :FLOOR
      @target_boiler_temp = @floor_watertemp_polycurve.float_value(@living_floor_thermostat.temp)
      @mixer_controller.set_target_temp(@floor_watertemp_polycurve.float_value(@living_floor_thermostat.temp))

    when :NONE
      @target_boiler_temp = 7.0

    end
    # End of determine_targets
  end

  # Control heating
  def control_heat(prev_power_needed,power_needed)

    changed = prev_power_needed[:power] == power_needed[:power]

    case power_needed[:power]
    when :HW
      # Set mode of the heater
      $app_logger.trace("Setting heater mode to HW")
      @buffer_heater.set_mode(:HW)
      @mixer_controller.stop_control
    when :RAD, :RADFLOOR, :FLOOR
      # Set mode and required water temperature of the boiler
      $app_logger.trace("Setting heater target temp to: "+@target_boiler_temp.to_s)
      @buffer_heater.set_target(@target_boiler_temp)
      if power_needed[:power] == :FLOOR
        $app_logger.trace("Setting heater mode to :floorheat")
        @buffer_heater.set_mode(:floorheat)
      else
        $app_logger.trace("Setting heater mode to :radheat")
        @buffer_heater.set_mode(:radheat)
      end
      if changed and prev_power_needed[:power] == :HW
        @mixer_controller.open
        @mixer_controller.start_control($config[:mixer_start_delay_after_HW])
      else
        @mixer_controller.start_control
      end
    else
      raise "Unexpected power_needed encountered in heating state: "+power_needed[:power].to_s
    end
  end

  # This function controls valves, pumps and heat during heating by evaluating the required power
  def control_pumps_valves_for_heating(prev_power_needed,power_needed)

    changed = ((prev_power_needed[:power] != power_needed[:power]) or (prev_power_needed[:state] != power_needed[:state]))

    $app_logger.debug("eval: "+((prev_power_needed[:power] != power_needed[:power]) or (prev_power_needed[:state] != power_needed[:state])).to_s)

    $app_logger.debug("Prev pn: "+prev_power_needed.to_s)
    $app_logger.debug("pn: "+power_needed.to_s)
    $app_logger.debug("Prev pnstate: "+prev_power_needed[:state].to_s)
    $app_logger.debug("pnstate: "+power_needed[:state].to_s)
    $app_logger.debug("powers deffer: "+(prev_power_needed[:power] != power_needed[:power]).to_s)
    $app_logger.debug("states deffer: "+(prev_power_needed[:state] != power_needed[:state]).to_s)

    $app_logger.debug("changed: "+changed.to_s)

    $app_logger.trace("Setting valves and pumps")

    case power_needed[:power]
    when :HW # Only Hot water supplies on
      if changed
        $app_logger.info("Setting valves and pumps for HW")

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
      if @basement_thermostat.is_on?
        @basement_radiator_valve.open
      else
        @basement_radiator_valve.delayed_close
      end

      if changed
        $app_logger.debug("Setting valves and pumps for RAD")
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
      if @basement_thermostat.is_on?
        @basement_radiator_valve.open
        @basement_floor_valve.open
      else
        @basement_radiator_valve.delayed_close
        @basement_floor_valve.delayed_close
      end

      if changed
        $app_logger.debug("Setting valves and pumps for RADFLOOR")

        # decide on floor valves based on external temperature
        if @living_floor_thermostat.is_on?
          @living_floor_valve.open
          @upstairs_floor_valve.open
        else
          @living_floor_valve.delayed_close
          @upstairs_floor_valve.delayed_close
        end

        # Floor heating on
        @floor_pump.on
        # Radiator pump on
        @radiator_pump.on
      end
    when :FLOOR
      # decide on basement valve based on basement temperature
      if @basement_thermostat.is_on?
        @basement_floor_valve.open
      else
        @basement_floor_valve.delayed_close
      end

      if changed
        $app_logger.debug("Setting valves and pumps for FLOOR")
        @basement_radiator_valve.delayed_close

        # decide on floor valves based on external temperature
        if @living_floor_thermostat.is_on?
          @living_floor_valve.open
          @upstairs_floor_valve.open
        else
          @living_floor_valve.delayed_close
          @upstairs_floor_valve.delayed_close
        end

        # Floor heating on
        @floor_pump.on
        @radiator_pump.off
      end
    end
  end

  # This function tells what kind of  power is needed
  def determine_power_needed
    if @moving_valves_required
      return :NONE
    elsif @mode != :mode_Off and @HW_thermostat.is_on?
      # Power needed for hot water - overrides Heat power need
      return :HW
    elsif @mode == :mode_Heat_HW and (@upstairs_thermostat.is_on? or \
    @living_thermostat.is_on? ) and \
    @living_floor_thermostat.is_off? and \
    @basement_thermostat.is_off?
      # Power needed for heating
      return :RAD
    elsif @mode == :mode_Heat_HW and (@upstairs_thermostat.is_on? or \
    @living_thermostat.is_on? ) and \
    (@living_floor_thermostat.is_on? or \
    @basement_thermostat.is_on?)
      # Power needed for heating and floor heating
      return :RADFLOOR
    elsif @living_floor_thermostat.is_on? or \
    @basement_thermostat.is_on?
      # Power needed for floor heating only
      return :FLOOR
    else
      # No power needed
      return :NONE
    end
  end

  def read_config
    begin
      $config_mutex.synchronize {$config = YAML.load_file(Globals::CONFIG_FILE_PATH)}
    rescue
      $app_logger.fatal("Cannot open config file: "+Globals::CONFIG_FILE_PATH+" Shutting down.")
      $shutdown_reason = Globals::FATAL_SHUTDOWN
    end

    $config_mutex.synchronize do
      @forward_sensor.mock_temp = $config[:forward_mock_temp] if (defined? @forward_sensor != nil)
      @return_sensor.mock_temp = $config[:return_mock_temp] if (defined? @return_sensor != nil)
      @HW_sensor.mock_temp = $config[:HW_mock_temp] if (defined? @HW_sensor != nil)

      @living_sensor.mock_temp = $config[:living_mock_temp] if (defined? @living_sensor != nil)
      @upstairs_sensor.mock_temp = $config[:upstairs_mock_temp] if (defined? @upstairs_sensor != nil)
      @basement_sensor.mock_temp = $config[:basement_mock_temp] if (defined? @basement_sensor != nil)
      @external_sensor.mock_temp = $config[:external_mock_temp] if (defined? @external_sensor != nil)
    end
  end

  def valve_move_evaluation

    # Only perform real check if time is between 11:00 and 11:15 in the morning
    return unless (((Time.now.to_i % (24*60*60))+ 60*60) > (10*60*60)) and
    (((Time.now.to_i % (24*60*60))+ 60*60) < (10.25*60*60))

    # If moving already scheduled then return
    return if @moving_valves_required

    # If there is no logfile we need to move
    if !File.exists?($config[:magnetic_valve_movement_logfile])
      @moving_valves_required = true
      $app_logger.info("No movement log file found - Setting moving_valves_required to true for the first time")
      return
    end

    # If there is a logfile we need to read it and evaluate movement need based on last log entry
    @move_logfile = File.new($config[:magnetic_valve_movement_logfile],"a+")
    @move_logfile.seek(0,IO::SEEK_SET)
    while (!@move_logfile.eof)
      lastline = @move_logfile.readline
    end

    seconds_between_move = $config[:magnetic_valve_movement_days] * 24*60*60

    # Move if moved later than the parameter read
    if lastline.to_i+seconds_between_move < Time.now.to_i and
    # And we are just after 10 o'clock
    ((Time.now.to_i % (24*60*60))+ 60*60) > (10*60*60)
      @moving_valves_required = true
      $app_logger.info("Setting moving_valves_required to true")
    end
    @move_logfile.close
  end

  def do_magnetic_valve_movement
    $app_logger.info("Start moving valves")

    @radiator_pump.off
    @floor_pump.off
    @hydr_shift_pump.off
    @hot_water_pump.off

    # First move without water circulation
    relay_movement_thread = Thread.new do
      Thread.current[:name] = "Relay movement thread"
      5.times do
        @buffer_heater.set_relays(:hydr_shifted)
        sleep 10
        @buffer_heater.set_relays(:buffer_passthrough)
        sleep 10
        @buffer_heater.set_relays(:feed_from_buffer)
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

      @buffer_heater.set_relays(:hydr_shifted)

      @radiator_pump.on
      @floor_pump.on
      @hydr_shift_pump.on

      sleep 10
      @buffer_heater.set_relays(:buffer_passthrough)
      sleep 10
      @hydr_shift_pump.off
      @buffer_heater.set_relays(:feed_from_buffer)
      sleep 10
      @radiator_pump.off
      @floor_pump.off
      sleep 2
      @basement_floor_valve.close
      @basement_radiator_valve.close
      @living_floor_valve.close
      @upstairs_floor_valve.close
      sleep 2
    end

    @buffer_heater.set_relays(:hydr_shifted)

    # Activate the hot water pump
    @hot_water_pump.on
    sleep 15
    @hot_water_pump.on

    @move_logfile = File.new($config[:magnetic_valve_movement_logfile],"a+")
    @move_logfile.write(Time.now.to_s)
    @move_logfile.write("\n")
    @move_logfile.write(Time.now.to_i.to_s)
    @move_logfile.write("\n")
    @move_logfile.close
    $app_logger.info("Moving valves finished")
  end

  # Perform app cycle logging
  def app_cycle_logging(power_needed)
    $app_logger.trace("Forward boiler temp: "+@forward_temp.to_s)
    $app_logger.trace("Return temp: "+@return_temp.to_s)
    $app_logger.trace("HW temp: "+@HW_thermostat.temp.to_s)
    $app_logger.trace("Need power: "+power_needed.to_s)
  end

  # Perform heating cycle logging
  def heating_cycle_logging(power_needed)
    return unless @logger_timer.expired?
    @logger_timer.reset

    $heating_logger.debug("LOGITEM BEGIN @"+Time.now.asctime)
    $heating_logger.debug("Active state: "+@heating_sm.current.to_s)

    sth=""
    @state_history.each {|e| sth+= ") => ("+e[:state].to_s+","+e[:power].to_s+","+(Time.now.getlocal(0)-e[:timestamp].to_i).strftime("%T")+" ago"}
    $heating_logger.debug("State and power_needed history : "+sth[5,1000]+")")
    $heating_logger.debug("Forward temperature: "+@forward_temp.round(2).to_s)
    $heating_logger.debug("Return water temperature: "+@return_temp.round(2).to_s)
    $heating_logger.debug("Delta T on the Boiler: "+(@forward_temp-@return_temp).round(2).to_s)
    $heating_logger.debug("Target boiler temp: "+@target_boiler_temp.round(2).to_s)

    $heating_logger.debug("\nHW temperature: "+@HW_thermostat.temp.round(2).to_s)

    $heating_logger.debug("\nExternal temperature: "+@living_floor_thermostat.temp.round(2).to_s)
    $heating_logger.debug("Mode thermostat status: "+@mode_thermostat.state.to_s)
    $heating_logger.debug("Operating mode: "+@mode.to_s)
    $heating_logger.debug("Need power: "+power_needed[:power].to_s)

    $heating_logger.debug("\nHW pump: "+@hot_water_pump.state.to_s)
    $heating_logger.debug("Radiator pump: "+@radiator_pump.state.to_s)
    $heating_logger.debug("Floor pump: "+@floor_pump.state.to_s)
    $heating_logger.debug("Hydr shift pump: "+@hydr_shift_pump.state.to_s)

    $heating_logger.debug("\nLiving target/temperature: "+@living_thermostat.threshold.to_s+"/"+@living_thermostat.temp.round(2).to_s)
    $heating_logger.debug("Living thermostat state: "+@living_thermostat.state.to_s)

    $heating_logger.debug("\nUpstairs target/temperature: "+@upstairs_thermostat.threshold.to_s+"/"+@upstairs_thermostat.temp.round(2).to_s)
    $heating_logger.debug("Upstairs thermostat state: "+@upstairs_thermostat.state.to_s)

    $heating_logger.debug("Living floor thermostat status: "+@living_floor_thermostat.state.to_s)
    $heating_logger.debug("Living floor valve: "+@living_floor_valve.state.to_s)
    $heating_logger.debug("Upstairs floor valve: "+@upstairs_floor_valve.state.to_s)

    $heating_logger.debug("\nBasement target/temperature: "+@basement_thermostat.target.to_s+"/"+@basement_thermostat.temp.round(2).to_s)
    $heating_logger.debug("Basement PWM value: "+(@basement_thermostat.value*100).round(0).to_s+"%")
    $heating_logger.debug("Basement floor valve: "+@basement_floor_valve.state.to_s)
    $heating_logger.debug("Basement thermostat status: "+@basement_thermostat.state.to_s)

    $heating_logger.debug("\nBoiler relay: "+@heater_relay.state.to_s)
    $heating_logger.debug("Boiler required temperature: "+@heating_watertemp.temp_required.round(2).to_s)
    $heating_logger.debug("LOGITEM END\n")
  end

  # Walk through states to test the state machine
  def apply_test_control()

    Thread.pass

    sleep(0.5)

    begin
      @test_controls = YAML.load_file(Globals::TEST_CONTROL_FILE_PATH)
    rescue
      $app_logger.fatal("Cannot open config file: "+Globals::TEST_CONTROL_FILE_PATH+" Shutting down.")
      $shutdown_reason = Globals::FATAL_SHUTDOWN
    end

    @forward_temp = @test_controls[:boiler_temp]
    @return_temp = @test_controls[:return_temp]

    @HW_thermostat.test_update(@test_controls[:HW_temp])
    @living_thermostat.test_update(@test_controls[:living_temp])

    @upstairs_thermostat.test_update(@test_controls[:upstairs_temp])
    @basement_thermostat.test_update(@test_controls[:basement_temp])
    @basement_thermostat.set_target(@test_controls[:target_basement_temp])

    @living_floor_thermostat.test_update(@test_controls[:external_temp])

    @living_thermostat.set_threshold(@test_controls[:target_living_temp])
    @upstairs_thermostat.set_threshold(@test_controls[:target_upstairs_temp])

    @HW_thermostat.set_threshold(@test_controls[:target_HW_temp])
    @target_boiler_temp = @test_controls[:target_boiler_temp]

    $app_logger.debug("Living floor PWM thermostat value: "+@living_floor_thermostat.value.to_s)
    $app_logger.debug("Living floor PWM thermostat state: "+@living_floor_thermostat.state.to_s)
    $app_logger.debug("Power needed: " + determine_power_needed.to_s)
    @test_cycle_cnt += 1

  end

  def shutdown
    # Turn off the heater
    @heating_sm.turnoff
    $app_logger.info("Shutdown complete. Shutdown reason: "+$shutdown_reason)
    command="rm -f "+$pidpath
    system(command)
  end

end

Thread.current["thread_name"] = "Starter thread"

RobustThread.logger = $daemon_logger

Signal.trap("TERM") do
  $shutdown_reason = Globals::NORMAL_SHUTDOWN
end

daemonize = ARGV.find_index("--daemon") != nil

pid = fork do
  main_rt = RobustThread.new(:label => "Main daemon thread") do

    Thread.current[:name] = "Main daemon"
    Signal.trap("HUP", "IGNORE")

    pidfile_index = ARGV.find_index("--pidfile")
    if pidfile_index != nil and ARGV[pidfile_index+1] != nil
      $pidpath = ARGV[pidfile_index+1]
    else
      $pidpath = Globals::PIDFILE
    end

    $app_logger.level = Globals::BoilerLogger::DEBUG if ARGV.find_index("--debug") != nil

    pidfile=File.new($pidpath,"w")
    pidfile.write(Process.pid.to_s)
    pidfile.close

    # Set the initial state
    boiler_control = Heating_controller.new(:Off,:Heat)
    $app_logger.info("Controller initialized - starting operation")

    begin
      boiler_control.operate
    rescue Exception => e
      $app_logger.fatal("Exception caught in main block: "+e.inspect)
      $app_logger.fatal("Exception backtrace: "+e.backtrace.join("\n"))
      $shutdown_reason = Globals::FATAL_SHUTDOWN
      boiler_control.shutdown
      exit
    end
  end
end

if daemonize
  Process.detach pid
else
  Process.wait
end
