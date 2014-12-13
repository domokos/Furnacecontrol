#!/usr/local/rvm/rubies/ruby-2.1.5/bin/ruby
# Boiler control softvare
# Ver 1 - 12 Dec 2014
#   - Initial coding work for RS485 bus based communication for the condensing boiler 
#   

require "/usr/local/lib/boiler_controller/boiler_base"
require "rubygems"
require "robustthread"
require "yaml"

$stdout.sync = true

$app_logger.level = Logger::INFO
$heating_logger.level = Logger::INFO

DRY_RUN = true
$shutdown_reason = Globals::NO_SHUTDOWN
$low_floor_temp_mode = false

Signal.trap("USR1") do
  $app_logger.level = Logger::INFO
  $heating_logger.level = Logger::DEBUG
end

Signal.trap("USR2") do
  $app_logger.level = Logger::INFO
  $heating_logger.level = Logger::INFO
end

Signal.trap("URG") do
  $app_logger.level = Logger::DEBUG
  $heating_logger.level = Logger::DEBUG
end

class Heating_State_Machine
  
  def initialize(initial_state,initial_mode)

    # Init class variables
    @target_boiler_temp = 0.0
    @forward_temp = 0.0
    @return_temp = 0.0
    @HW_temp = 0.0
    @test_cycle_cnt = 0
    @cycle = 0.0
    @moving_valves_required = false
    @config = []
    
    read_config
    
    @logger_timer = Globals::TimerSec.new(@config[:logger_delay_whole_sec],"Logging Delay Timer")
      
    # Define the operation modes of the furnace
    @mode_Off = BoilerBase::Mode.new("Switched off","Switched off state, frost and anti-legionella protection")
    @mode_HW = BoilerBase::Mode.new("HW","Hot water only")
    @mode_Heat_HW = BoilerBase::Mode.new("Heat","Heating and hot water")
    
    # Create pumps
    @radiator_pump = BusDevice::Switch.new("Radiator pump", "In the basement boiler room - Contact 1 on Main Panel", 11, 5, DRY_RUN)
    @floor_pump = BusDevice::Switch.new("Floor pump", "In the basement boiler room - Contact 2 on Main Panel", 11, 6, DRY_RUN)
    @hidr_shift_pump = BusDevice::Switch.new("Hidraulic shift pump", "In the basement boiler room - Contact 3 on Main Panel", 11, 7, DRY_RUN)
    @hot_water_pump = BusDevice::Switch.new("Hot water pump", "In the basement boiler room - Contact 4 on Main Panel", 11, 8, DRY_RUN)

    # Create temp sensors
    @forward_sensor = BusDevice::TempSensor.new("Forward boiler temperature", "On the forward piping of the boiler", 11, 4, DRY_RUN, @config[:forward_mock_temp])
    @return_sensor = BusDevice::TempSensor.new("Return water temperature", "On the return piping of the boiler", 11, 3, DRY_RUN, @config[:return_mock_temp])
    @HW_sensor = BusDevice::TempSensor.new("Hot Water temperature","Inside the Hot water container main sensing tube", 11, 1, DRY_RUN, @config[:HW_mock_temp])

    @living_sensor = BusDevice::TempSensor.new("Living room temperature","Temperature in the living room", 12, 1, true, @config[:living_mock_temp])
    @upstairs_sensor = BusDevice::TempSensor.new("Upstairs temperature","Upstairs forest room", 12, 2, true, @config[:upstairs_mock_temp])
    @basement_sensor = BusDevice::TempSensor.new("Basement temperature","In the sauna rest area", 11, 2, DRY_RUN, @config[:basement_mock_temp])
    @external_sensor = BusDevice::TempSensor.new("External temperature","On the northwestern external wall", 12, 2, true, @config[:external_mock_temp])

    # Create the is_HW or valve movement proc for the floor PWM thermostats
    @is_HW_or_valve_proc = proc {
        determine_power_needed == "HW" or @moving_valves_required == true
    }
    
    # Create the value proc for the living floor thermostat.
    @living_floor_thermostat_valueproc = lambda { |sample_filter, target| 
      if $low_floor_temp_mode
        if sample_filter.value < -1
          return 0.2
        else
          return 0
        end
      else
        # This is now fixed to : 0.2 @ 13 and 0.8 @ 6 Celsius above 13, zero, below 6 full power (+- of the sample_filter.value shifts curve)
        tmp = 1.31429 - (sample_filter.value-1) * 0.085714
        tmp = 0 if tmp < 0.2 
        tmp = 1 if tmp > 0.8 
        return tmp
      end
      }

    # Create the value proc for the upstairs floor thermostat.
    @upstairs_floor_thermostat_valueproc = lambda { |sample_filter, target|
      if $low_floor_temp_mode
        if sample_filter.value < -6
          return 0
        else
          return 0.2
        end
      else
    # This is now fixed to : 0.2 @ 13 and 0.8 @ 6 Celsius above 13, zero, below 6 full power (+- of the sample_filter.value shifts curve)
        tmp = 1.31429 - (sample_filter.value-1) * 0.085714
        tmp = 0 if tmp < 0.2 
        tmp = 1 if tmp > 0.8 
        return tmp
      end
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
    @living_thermostat = BoilerBase::Symmetric_thermostat.new(@living_sensor,0.3,0.0,8)
    @HW_thermostat = BoilerBase::Asymmetric_thermostat.new(@HW_sensor,2,2,0.0,8)
    @living_floor_thermostat = BoilerBase::PwmThermostat.new(@external_sensor,10,@living_floor_thermostat_valueproc,@is_HW_or_valve_proc)
    @mode_thermostat = BoilerBase::Symmetric_thermostat.new(@external_sensor,0.8,5.0,8)
    @upstairs_floor_thermostat = BoilerBase::PwmThermostat.new(@external_sensor,10,@upstairs_floor_thermostat_valueproc,@is_HW_or_valve_proc)
    @upstairs_thermostat = BoilerBase::Symmetric_thermostat.new(@upstairs_sensor,0.3,5.0,8)
    @basement_thermostat = BoilerBase::PwmThermostat.new(@basement_sensor,10,@basement_thermostat_valueproc,@is_HW_or_valve_proc)

    #Technical targets must be set to allow PWM proc to detect changes
    @upstairs_floor_thermostat.set_target(0)
    @living_floor_thermostat.set_target(0)
    
    # Create magnetic valves
    @basement_floor_valve = BusDevice::DelayedCloseMagneticValve.new("Basement floor valve","Contact 5 on main board" ,11 , 9, DRY_RUN)
    @basement_radiator_valve = BusDevice::DelayedCloseMagneticValve.new("Basement radiator valve","Contact 8 on main board", 11, 10, DRY_RUN)
    @living_floor_valve = BusDevice::DelayedCloseMagneticValve.new("Living level floor valve","In the living floor water distributor", 12 , 1, true)
    @upstairs_floor_valve = BusDevice::DelayedCloseMagneticValve.new("Upstairs floor valve","In the upstairs water distributor",12, 3, true)

    # Create heater relay valves
    @heater_relay = BusDevice::Switch.new("Heater relay","Heater contact on main panel", 11, 11, DRY_RUN)
    @watertemp = BusDevice::WaterTemp.new("Boiler water temp regulator", "Wiper contact on main panel", 11, 12, DRY_RUN)

    # Define the states of the furnace
    @state_Off = BoilerBase::State.new(:Off,"Boiler switched off")
    @state_Heat = BoilerBase::State.new(:Heat,"Heating to the target temperature with PD controll")
    @state_Postheat = BoilerBase::State.new(:Postheat,"Post ciculation with heating")
    @state_PostHW = BoilerBase::State.new(:PostHW,"Post circulation w/o heating")

    # Define the activating actions of each state
    # Activation actions for Off satate
    @state_Off.set_activate(
    proc {
      $app_logger.debug("Activating \"Off\" state")

      # Turn off heater relay
      @heater_relay.off

      # Wait before turning pumps off to make sure we do not lose circulation
      sleep @config[:circulation_maintenance_delay]
            
      # Turn off all pumps
      @radiator_pump.off
      @floor_pump.off
      @hidr_shift_pump.off
      @hot_water_pump.off
      
      # Close all valves
      @basement_floor_valve.delayed_close
      @basement_radiator_valve.delayed_close
      @living_floor_valve.delayed_close
      @upstairs_floor_valve.delayed_close
      
    })

    # Activation actions for Heating 1st gear
    @state_Heat.set_activate(
    proc {
      $app_logger.debug("Activating \"Heat\" state")
      # Do not control pumps and valves 
    })

    # Activation actions for Post circulation heating
    @state_Postheat.set_activate(
    proc {
      $app_logger.debug("Activating \"Postheat\" state")

      # Turn off heater relay
      @heater_relay.off

      # All radiator valves open
      @basement_radiator_valve.open

      # Radiator pumps on
      @hidr_shift_pump.on
      @radiator_pump.on

      # Wait before turning pumps off to make sure we do not lose circulation
      sleep @config[:circulation_maintenance_delay]
      @floor_pump.off
      @hot_water_pump.off

      # All floor valves closed
      @basement_floor_valve.delayed_close
      @living_floor_valve.delayed_close
      @upstairs_floor_valve.delayed_close
      
    })

    # Activation actions for Post circulation HW only
    @state_PostHW.set_activate(
    proc {
      $app_logger.debug("Activating \"PostHW\" state")

      # Turn off heater relay
      @heater_relay.off

      @hot_water_pump.on
      # Wait before turning pumps off to make sure we do not lose circulation
      sleep @config[:circulation_maintenance_delay]
      
      # Only HW pump on
      @radiator_pump.off
      @floor_pump.off
      @hidr_shift_pump.off

      # All valves are closed
      @basement_floor_valve.delayed_close
      @basement_radiator_valve.delayed_close
      @living_floor_valve.delayed_close
      @upstairs_floor_valve.delayed_close
      
    })


    # Set the initial state
    if (initial_state == :Off)
      @state = @state_Off
      @state.activate

      @hist_state1 = @hist_state2 = @hist_state3 = @hist_state4 = @state
    else
      $app_logger.fatal("Illegal initial state. Aborting.")
      exit
    end
    
    # Set the initial mode
    if initial_mode == :Off
      @mode = @mode_Off
    elsif initial_mode == :HW
      @mode = @mode_HW
    elsif initial_mode == :Heat
      @mode = @mode_Heat_HW
    else
      $app_logger.fatal("Illegal initial mode. Aborting.")
      exit
    end

    # Prefill sensors and thermostats to ensure smooth startup operation
    for i in 0..20 do
      read_sensors
      determine_targets(determine_power_needed)
      sleep 1.5
    end

    $app_logger.debug("Boiler controller initialized initial state set to: "+@state.description+", Initial mode set to: "+@mode.description)

  end

# The function evaluating states and performing necessary
# transitions basd on the current value of sensors
  def evaluate_state_change(power_needed)
    case @state.name
    # The evaluation of the Off state
    when :Off
      $app_logger.debug("Evaluating Off state:")
      $app_logger.debug("\tIf need power then -> Heat")
      $app_logger.debug("\tIf furnace temp increases and furnace above HW temp + 7 C in HW mode then -> PostHW")
      $app_logger.debug("\tIf furnace temp increases and furnace above HW temp + 7 C not in HW mode then -> PostHeat")        
      $app_logger.debug("\tElse: Stay in Off state")
      if power_needed != :NONE
        $app_logger.debug("Decision: Need power changing state to Heat")
        $app_logger.debug("power_needed: "+power_needed.to_s)
        @state = @state_Heat
        @state.activate()
      else
        $app_logger.debug("Decision: No power requirement - not changing state")
      end

    when :Heat
      $app_logger.debug("Evaluating Heat state:")
      $app_logger.debug("\tControl valves and pumps based on measured temperatures")
      $app_logger.debug("\tControl burners to maintain target furnace temperature")
      $app_logger.debug("\tIf not need power anymore then -> Postheat or PostHW based on operating mode")
   
      # If not need power anymore then -> Postheat or PostHW
      if power_needed == :NONE and @mode == @mode_HW
        $app_logger.debug("Decision: No more power needed in HW mode - changing state to PostHW")
        $app_logger.debug("power_needed: NONE")
        @state = @state_PostHW
        @state.activate()
      elsif power_needed == :NONE
        $app_logger.debug("Decision: No more power needed not in HW mode - changing state to Postheat")
        $app_logger.debug("power_needed: NONE")
        @state = @state_Postheat
        @state.activate()
      else
        # Control valves, pumps and boiler based on measured temperatures
        control_pumps_valves_and_heat(power_needed)
      end

    when :Postheat
      $app_logger.debug("Evaluating Postheat state:")
      $app_logger.debug("\tIf Delta T on the Furnace drops below 5 C then -> Off")
      $app_logger.debug("\tIf need power is not false then -> Heat")

      # If Delta T on the Furnace drops below 5 C then -> Off
      if @forward_temp - @return_temp < 5.0
        $app_logger.debug("Decision: Delta T on the Furnace dropped below 5 C - changing state to Off")
        @state = @state_Off
        @state.activate()
      # If need power then -> Heat
      elsif power_needed != :NONE
        $app_logger.debug("Decision: Need power is "+power_needed.to_s+" - changing state to Heat")
        @state = @state_Heat
        @state.activate()
      end

    when :PostHW
      $app_logger.debug("Evaluating PostHW state:")
      $app_logger.debug("\tIf Delta T on the Furnace drops below 5 C then -> Off")
      $app_logger.debug("\tIf Furnace temp below HW temp + 4 C then -> Off")
      $app_logger.debug("\tIf need power is not false then -> Heat")

      # If Delta T on the Furnace drops below 5 C then -> Off
      if @forward_temp - @return_temp < 5.0
        $app_logger.debug("Decision: Delta T on the Furnace dropped below 5 C - changing state to Off")
        @state = @state_Off
        @state.activate()
      # If Furnace temp below HW temp + 4 C then -> Off
      elsif @forward_temp < @HW_thermostat.temp + 4 
          $app_logger.debug("Decision: Furnace temp below HW temp + 4 C  - changing state to Off")
          @state = @state_Off
          @state.activate()        
      # If need power then -> Heat
      elsif power_needed != :NONE
        $app_logger.debug("Decision: Need power is "+power_needed.to_s+" - changing state to Heat")
        @state = @state_Heat
        @state.activate()
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
    @upstairs_floor_thermostat.update
    @mode_thermostat.update
  end
  
# Read the target temperatures, determine targets and operating mode
  def determine_targets(power_needed)
    # Read the config file
    read_config
    
    @living_thermostat.set_threshold(@config[:target_living_temp])
    @upstairs_thermostat.set_threshold(@config[:target_upstairs_temp])
    @basement_thermostat.set_target(@config[:target_basement_temp])
    @mode_thermostat.set_threshold(@config[:mode_threshold])
    @HW_thermostat.set_threshold(@config[:target_HW_temp])

    if @mode_thermostat.is_on?
       @state.name != :Heat and @mode = @mode_Heat_HW
    else
       @state.name != :Heat and @mode = @mode_HW
    end
    @HW_thermostat.set_histeresis(2,2)

    case power_needed
    when :HW
      @target_boiler_temp = 85.0

    when :RAD, :RADFLOOR
      # Use @living_floor_thermostat.temp to get a filtered external temperature
      @target_boiler_temp = -0.83*@living_floor_thermostat.temp+37.5
      if @target_boiler_temp > 70.0
        @target_boiler_temp = 70.0
      elsif @target_boiler_temp < 35.0
        @target_boiler_temp = 35.0
      end
    
    when :FLOOR
      @target_boiler_temp = 35.0

    when :NONE
      @target_boiler_temp = 7.0

    end  
    
    
  end

  
# The main loop of the controller
  def operate
    @cycle = 0
    @state_history = Array.new(4,[@state.name, determine_power_needed])
      
    # Do the main loop until shutdown is requested
    while($shutdown_reason == Globals::NO_SHUTDOWN) do

      $app_logger.debug("Main boiler loop cycle: "+@cycle.to_s)

      sleep @config[:main_loop_delay]
      
      if !DRY_RUN
        read_sensors
        power_needed = determine_power_needed
        determine_targets(power_needed)
      else
        apply_test_control
      end

      # Call the state machine state transition decision method
      evaluate_state_change(power_needed)

      # If magnetic valve movement is required then carry out moving process
      if @moving_valves_required and @state.name == :Off
            do_magnetic_valve_movement
            @moving_valves_required = false
      end

      # Record state history for 4 states
      if @state_history.last[0] != @state.name or @state_history.last[1] != power_needed  
        @state_history.shift
        @state_history.push([@state.name,power_needed])
      end

      # Increment the cycle and reset it if 40 cycles is reached
      @cycle = 0 if @cycle % 40 == 0 
      @cycle = @cycle + 1

      $app_logger.debug("Forward boiler temp: "+@forward_temp.to_s)
      $app_logger.debug("Return temp: "+@return_temp.to_s)
      $app_logger.debug("HW temp: "+@HW_thermostat.temp.to_s)
      $app_logger.debug("Need power: "+power_needed.to_s)
      
      heating_logging(power_needed)
      
      # Check Move if time is between 11:00 and 11:15 in the morning
      if (((Time.now.to_i % (24*60*60))+ 60*60) > (10*60*60)) and
       (((Time.now.to_i % (24*60*60))+ 60*60) < (10.25*60*60))
          magnetic_valve_move_evaluation
      end
    end
    shutdown
  end


  def magnetic_valve_move_evaluation
    # If moving already required then return
    return if @moving_valves_required
    
    # If there is no logfile we need to move
    if !File.exists?(@config[:magnetic_valve_movement_logfile])
      @moving_valves_required = true
      $app_logger.info("No movement log file found - Setting moving_valves_required to true for the first time")
      return
    end
    
    # If there is a logfile we need to read it and evaluate movement need based on last log entry
    @move_logfile = File.new(@config[:magnetic_valve_movement_logfile],"a+")
    @move_logfile.seek(0,IO::SEEK_SET)
    while (!@move_logfile.eof)
      lastline = @move_logfile.readline
    end

    seconds_between_move = @config[:magnetic_valve_movement_days] * 24*60*60

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
    @hidr_shift_pump.off
    @hot_water_pump.off

    repeat = 5
    while (repeat>0)
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
        repeat = repeat-1
    end 

    repeat = 5
    while (repeat>0)
        @basement_floor_valve.open
        @basement_radiator_valve.open
        @living_floor_valve.open
        @upstairs_floor_valve.open
        @radiator_pump.on
        @floor_pump.on
        @hidr_shift_pump.on
      
        sleep 20
        @radiator_pump.off
        @floor_pump.off
        @hidr_shift_pump.off
        sleep 2
        @basement_floor_valve.close
        @basement_radiator_valve.close
        @living_floor_valve.close
        @upstairs_floor_valve.close
        sleep 2
        repeat = repeat-1
    end
    @move_logfile = File.new("/var/log/furnace_valve_log","a+")
    @move_logfile.write(Time.now.to_s)
    @move_logfile.write("\n")
    @move_logfile.write(Time.now.to_i.to_s)
    @move_logfile.write("\n")
    @move_logfile.close
    $app_logger.info("Moving valves finished")
  end
  
  def heating_logging(power_needed)
    return unless @logger_timer.expired?
    @logger_timer.reset
    
    $heating_logger.debug("LOGITEM BEGIN @"+Time.now.asctime)
    $heating_logger.debug("Active state: "+@state.name.to_s)
    sth=""
    @state_history.each {|e| sth+= ") => ("+e*","}
    $heating_logger.debug("State and power_needed history : "+sth[5,1000]+")")
    $heating_logger.debug("Forwared temperature: "+@forward_temp.round(2).to_s)
    $heating_logger.debug("Return water temperature: "+@return_temp.round(2).to_s)
    $heating_logger.debug("Delta T on the Boiler: "+(@forward_temp-@return_temp).round(2).to_s)
    $heating_logger.debug("Target boiler temp: "+@target_boiler_temp.round(2).to_s)

    $heating_logger.debug("\nHW temperature: "+@HW_thermostat.temp.round(2).to_s)
    
    $heating_logger.debug("\nExternal temperature: "+@living_floor_thermostat.temp.round(2).to_s)
    $heating_logger.debug("Mode thermostat status: "+@mode_thermostat.state.to_s)
    $heating_logger.debug("Operating mode: "+@mode.description)
    $heating_logger.debug("Need power: "+power_needed.to_s)

    $heating_logger.debug("\nHW pump: "+@hot_water_pump.state.to_s)
    $heating_logger.debug("Radiator pump: "+@radiator_pump.state.to_s)
    $heating_logger.debug("Floor pump: "+@floor_pump.state.to_s)
    $heating_logger.debug("Hidr shift pump: "+@hidr_shift_pump.state.to_s)

    $heating_logger.debug("\nLiving temperature: "+@living_thermostat.temp.round(2).to_s)
    $heating_logger.debug("Living thermostat status: "+@living_thermostat.state.to_s)
        
    $heating_logger.debug("\nUpstairs temperature: "+@upstairs_thermostat.temp.round(2).to_s)
    $heating_logger.debug("Upstairs thermostat status: "+@upstairs_thermostat.state.to_s)
    
    $heating_logger.debug("\nLiving floor PWM value: "+@living_floor_thermostat.value.round(2).to_s)
    $heating_logger.debug("Living floor valve: "+@living_floor_valve.state.to_s)
    $heating_logger.debug("Living floor thermostat status: "+@living_floor_thermostat.state.to_s)

    $heating_logger.debug("\nUpstairs floor PWM value: "+@upstairs_floor_thermostat.value.round(2).to_s)
    $heating_logger.debug("Upstairs floor valve: "+@upstairs_floor_valve.state.to_s)
    $heating_logger.debug("Upstairs floor thermostat status: "+@upstairs_floor_thermostat.state.to_s)
    
    $heating_logger.debug("\nBasement temperature: "+@basement_thermostat.temp.round(2).to_s)
    $heating_logger.debug("Basement PWM value: "+@basement_thermostat.value.round(2).to_s)
    $heating_logger.debug("Basement floor valve: "+@basement_floor_valve.state.to_s)
    $heating_logger.debug("Basement thermostat status: "+@basement_thermostat.state.to_s)
         
    $heating_logger.debug("\nBoiler relay: "+@heater_relay.state.to_s)
    $heating_logger.debug("Boiler required temperature: "+@watertemp.temp_required.round(2).to_s)
    $heating_logger.debug("LOGITEM END\n")
  end

  # This function controls valves, pumps and heat during heating by evaluating the required power
  def control_pumps_valves_and_heat(power_needed)
    $app_logger.debug("Controlling valves and pumps")
    
    case power_needed
      when :HW # Only Hot water supplies on
        $app_logger.info("Setting valves and pumps for HW")
        # Only HW pump on
        @hot_water_pump.on

        # Wait before turning pumps off to make sure we do not lose circulation
        sleep @config[:circulation_maintenance_delay]
        @radiator_pump.off
        @floor_pump.off
        @hidr_shift_pump.off
  
        # All valves are closed
        @basement_floor_valve.delayed_close
        @basement_radiator_valve.delayed_close
        @living_floor_valve.delayed_close
        @upstairs_floor_valve.delayed_close
  
      when :RAD # Only Radiator pumps on
        $app_logger.debug("Setting valves and pumps for RAD")
        @basement_floor_valve.delayed_close
        @living_floor_valve.delayed_close
        @upstairs_floor_valve.delayed_close
  
        #  decide on basement radiator valve
        if @basement_thermostat.is_on?
          @basement_radiator_valve.open
        else
          @basement_radiator_valve.delayed_close
        end
  
        # Control basic pumps
        @hidr_shift_pump.on
        # Radiator pump on
        @radiator_pump.on

        # Wait before turning pumps off to make sure we do not lose circulation
        sleep @config[:circulation_maintenance_delay]
        @hot_water_pump.off
 
        # Floor heating off
        @floor_pump.off
  
      when :RADFLOOR
        $app_logger.debug("Setting valves and pumps for RADFLOOR")
        # decide on living floor valve based on external temperature
        if @living_floor_thermostat.is_on?
          @living_floor_valve.open
        else
          @living_floor_valve.delayed_close
        end
  
        # decide on upstairs floor valve based on external temperature
        if @upstairs_floor_thermostat.is_on?
          @upstairs_floor_valve.open
        else
          @upstairs_floor_valve.delayed_close
        end
  
        # decide on basement valves based on basement temperature
        if @basement_thermostat.is_on?
          @basement_radiator_valve.open
          @basement_floor_valve.open
        else
          @basement_radiator_valve.delayed_close
          @basement_floor_valve.delayed_close
        end
  
        @hidr_shift_pump.on

        # Floor heating on
        @floor_pump.on

        # Radiator pump on
        @radiator_pump.on
        
        # Wait before turning pumps off to make sure we do not lose circulation
        sleep @config[:circulation_maintenance_delay]
        @hot_water_pump.off
      
      when :FLOOR
        $app_logger.debug("Setting valves and pumps for FLOOR")
        # decide on living floor valve based on external temperature
        if @living_floor_thermostat.is_on?
          @living_floor_valve.open
        else
          @living_floor_valve.delayed_close
        end
  
        # decide on upstairs floor valve based on external temperature
        if @upstairs_floor_thermostat.is_on?
          @upstairs_floor_valve.open
        else
          @upstairs_floor_valve.delayed_close
        end
        
        # decide on basement valve based on basement temperature
        if @basement_thermostat.is_on?
          @basement_floor_valve.open
        else
          @basement_floor_valve.delayed_close
        end
  
        @basement_radiator_valve.delayed_close
  
        @hidr_shift_pump.on
        # Floor heating on
        @floor_pump.on
        
        # Wait before turning pumps off to make sure we do not lose circulation
        sleep @config[:circulation_maintenance_delay]
        @hot_water_pump.off
        @radiator_pump.off
      end
      if power_needed != :NONE
        # Set required water temperature of the boiler
        @watertemp.set_water_temp(@target_boiler_temp)
    
        # Turn on heater relay of the boiler to activate heating
        @heater_relay.on
      else
        # Set required water temperature of the boiler
        @watertemp.set_water_temp(@target_boiler_temp)
    
        # Turn on heater relay of the boiler to activate heating
        @heater_relay.off
      end
  end

  # This function tells what kind of  power is needed
  def determine_power_needed
    if @moving_valves_required
      return :NONE
    elsif @mode != @mode_Off and @HW_thermostat.is_on?
      # Power needed for hot water - overrides Heat power need
      return :HW
    elsif @mode == @mode_Heat_HW and (@upstairs_thermostat.is_on? or \
      @living_thermostat.is_on? ) and \
      @living_floor_thermostat.is_off? and \
      @upstairs_floor_thermostat.is_off? and \
      @basement_thermostat.is_off?
      # Power needed for heating
      return :RAD
    elsif @mode == @mode_Heat_HW and (@upstairs_thermostat.is_on? or \
      @living_thermostat.is_on? ) and \
      (@living_floor_thermostat.is_on? or \
       @upstairs_floor_thermostat.is_on? or \
             @basement_thermostat.is_on?)
      # Power needed for heating and floor heating
      return :RADFLOOR
    elsif @living_floor_thermostat.is_on? or \
      @upstairs_floor_thermostat.is_on? or \
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
      @config = YAML.load_file(Globals::CONFIG_FILE_PATH)
    rescue
      $app_logger.fatal("Cannot open config file: "+Globals::CONFIG_FILE_PATH+" Shutting down.")
      $shutdown_reason = Globals::FATAL_SHUTDOWN
    end  

    @forward_sensor.mock_temp = @config[:forward_mock_temp] if (defined? @forward_sensor != nil) 
    @return_sensor.mock_temp = @config[:return_mock_temp] if (defined? @return_sensor != nil)
    @HW_sensor.mock_temp = @config[:HW_mock_temp] if (defined? @HW_sensor != nil)

    @living_sensor.mock_temp = @config[:living_mock_temp] if (defined? @living_sensor != nil)
    @upstairs_sensor.mock_temp = @config[:upstairs_mock_temp] if (defined? @upstairs_sensor != nil)
    @basement_sensor.mock_temp = @config[:basement_mock_temp] if (defined? @basement_sensor != nil)
    @external_sensor.mock_temp = @config[:external_mock_temp] if (defined? @external_sensor != nil)
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
    @upstairs_floor_thermostat.test_update(@test_controls[:external_temp])

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
    @state = @state_Off
    @state.activate
    $app_logger.info("Shutting down. Shutdown reason: "+$shutdown_reason)
    command="rm -f "+$pidpath
    system(command)
  end

end



Thread.current["thread_name"] = "Main thread"

RobustThread.logger = $daemon_logger

Signal.trap("TERM") do
  $shutdown_reason = Globals::NORMAL_SHUTDOWN
end

pid = fork do
  main_rt = RobustThread.new(:label => "Main daemon thread") do

    Signal.trap("HUP", "IGNORE")
  
    if ARGV[0] != nil
      $pidpath = ARGV[0]
    else
      $pidpath = Globals::PIDFILE
    end
    pidfile=File.new($pidpath,"w")
    pidfile.write(Process.pid.to_s)
    pidfile.close
  
    # Set the initial state
    boiler_control = Heating_State_Machine.new(:Off,:Heat)
    $app_logger.info("Controller initialized - starting operation")
    
    boiler_control.operate
  end
end
Process.detach pid
