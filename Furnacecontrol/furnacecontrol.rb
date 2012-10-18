#!/usr/bin/ruby
# Furnace control softvare
# Rev 36 - 22 Jun 2012
# Changes over v44:
#   - Reorganize PostHW by implementing a furnace_analyzer to track furnace temp change trends 
#   - Todo: implement  off_time recalculation for PWM
# Rev 4 - 22 Sep 2011
# Changes over v44:
#   - Move anti-clogging valve movement days parameter in a config file 
#   - Todo: implement  off_time recalculation for PWM
#
# Version 44 - 13 Oct 2010
# Changes over v43:
#   - Replace owfs with Onewire module
#   - Todo: implement  off_time recalculation for PWM
#
# Version 43 - 7 Oct 2010
# Changes over v42:
#   - Implementing proper daemonizing
#   - Todo: implement  off_time recalculation for PWM
#
# Version 42 - 13 May 2010
# Changes over v41:
#   - Implementing periodic magnetic valve moves to prevent clogging
#   - Todo: implement  off_time recalculation for PWM
#
# Version 41 - 23 Feb 2010
# Changes over v39:
#   - Changing to owfs_v5 to place a limit on owfs restart try count
#   - Todo: implement  off_time recalculation for PWM
#
# Version 40 - 18 Dec 2009
# Changes over v39:
#   - Splitting out furnace_base
#   - Introducing the ability of multiple sensor reliance for thermostats by setting up a 3 second read expiry for sensors to avoide unnecessary owfs read (conversion) delays
#   - Introducing upstairs_floor thermostat also based on external_sensor
#   - Cleaned up timers. Now timer objects are recreated with new instead of being restarted - unnecessary garbage collection
#   - Todo: implement  off_time recalculation for PWM
#
# Version 39 - 27 Jun 2009
# Changes over v38:
#   - Introduced assymetric_thermostat to harness remaining power in the furnace for HW only operation mode
#   - Todo: implement  off_time recalculation for PWM
#
# Changes over v37:
#   - Clean up shutdown control
#   - Introduced mode_thermostat to detemine postheating stategy based on external temperature
#   - Todo: implement  off_time recalculation for PWM
#
# Version 37 - 1 Jun 2009
# Changes over v36:
#   - Introducing histeresis in ControlHeat
#   - Todo: implement  off_time recalculation for PWM
#
# Version 36 - 27 Apr 2009
# Changes over v35:
#   - All switches are forced open and close, no soft state check before owfs command issuing
#   - Todo: implement  off_time recalculation for PWM
#
# Version 35 - 16 Apr 2009
# Changes over v34:
#   - New version of owfs (owfs_v3) to handle read exceptions on sensors and switches by remounting owfs and restarting furnace
#   - Force close and open switches in owfs and use of these in Off state activation
#   - Todo: implement  off_time recalculation for PWM
#
# Version 34 - 30 Mar 2009
# Changes over v33:
#   - Adding reset functionality to Filter and PD_controller classes
#   - Adding reset (stop) functionality to Furnace_PWM class
#   - Resetting filtered_furnace_temp, furnace_pd_controller and furnace_pwm upon Heat state activation
#   - Removing Preheat states
#   - Todo: implement  off_time recalculation for PWM
#
# Version 33 - 1 Mar 2009
# Changes over v32:
#   - Adjust timing between PWM outputs 
#   - Todo: implement  off_time recalculation for PWM
#
# Version 32 - 7 Jan 2009
# Changes over v31:
#   - PWM concept for heat control removing various states and introducing a single Heat state
#     with PWM control
#   - Todo: implement  off_time recalculation for PWM
#
# Version 31 - 16 Nov 2008
# Changes over v30:
#   - Closing upstairs floor valve permanently
#
# Version 30 - 15 Nov 2008
# Changes over v29:
#   - Opening up upstairs floor valve along the same logic as living floor valve
#   - Modifying logic to make floor heating dependent upon external temperature even when Rad is active
#   - Fixed upstairs floor valve address
#


require "/usr/local/bin/onewire"
require "/usr/local/bin/furnace_base"
require "rubygems"
require "robustthread"

$stdout.sync = true

# Debuglevel 	1 - print state changes and measurements
#		2 - print detailed evaluation information
$debuglevel = 0
$do_tests = false
$logging_active = false
$overheat_log_threshold = 95.0
$onewire_restart_log = false
$shutdown_requested = false
$low_floor_temp_mode = false
$upstairs_floor_unconditionally_on = false

Signal.trap("USR1") do
	$logging_active = true
	$control_logging = false
end

Signal.trap("USR2") do
	$logging_active = false
	$control_logging = false
end

Signal.trap("URG") do
	$control_logging = true
	$logging_active = false
end

# This Magnetic valve closes with a delay to decrease shockwawe effects in the system
class DelayedCloseMagneticValve < Onewire::DS_240X
# The closing delay is 2 seconds
  @@close_delay = 2

  def initialize(name,location,id,pioid,do_tests)
    @name = name
    @id = id
    @location = location
    @do_tests = do_tests
    @pioid = pioid
    if @pioid != nil
      @path = "/" + @id + "/PIO." + @pioid
    else
      @path = "/" + @id + "/PIO"
    end
        
    @state="unknown"
    @semaphore = Mutex.new
    !@do_tests and off
    @state = "off"
  end
  
  def delayed_off
    if @state != "off"
     RobustThread.new(:label => "DelayedCloseMagneticValve Class delayed close thread: "+@name) do
       @semaphore.synchronize{
         sleep @@close_delay
         !@do_tests and write_path("0")
         @state = "off"
       }
     end
    end
   end
   
  def delayed_close  
    delayed_off
  end

  def on
    @semaphore.synchronize{
      if @state != "on"
        !@do_tests and write_path("1")
        @state = "on"
      end
    }
  end

  def off
    @semaphore.synchronize{
      if @state != "off"
        !@do_tests and write_path("0")
        @state = "off"
      end
    }
  end
end

class State_Machine
	def initialize(initial_state,initial_mode)

		# Init class variables
		@target_furnace_temp = 0.0
		@furnace_temp = 0.0
		@return_temp = 0.0
		@HW_temp = 0.0
		@test_cycle_cnt = 0
		@cycle = 0.0
		@moving_valves_required = false
		
		#	Define the operation modes of the furnace
		@mode_Off = Mode.new("Switched off","Switched off state, frost and anti-legionella protection")
		@mode_HW = Mode.new("HW","Hot water only")
		@mode_Heat = Mode.new("Heat","Heating and hot water")
		
		#	Create pumps
		@radiator_pump = Onewire::DS_2406.new("Radiator pump","Contact 3 on main panel","12.6E6B58000000","B",$do_tests)
		@floor_pump = Onewire::DS_2406.new("Floor pump","Contact 4 on main panel","12.032A5F000000","B",$do_tests)
		@hidr_shift_pump = Onewire::DS_2406.new("Hidraulic shift pump","Contact 6 on main panel","12.032A5F000000","A",$do_tests)
		@hot_water_pump = Onewire::DS_2405.new("Hot water pump","Contact 5 on main panel","05.BAFB31000000",$do_tests)

		#	Create temp sensors
		@furnace_sensor = Onewire::DS_18S20.new("Furnace temperature","Inside the furnace main sensing tube","10.FE0524010800",0)
		@return_sensor = Onewire::DS_18B20.new("Return water temperature","AT the return pipe before the furnace","28.912D50010000","11",3)
		@HW_sensor = Onewire::DS_18S20.new("Hot Water temperature","Inside the Hot water container main sensing tube","10.C7A223010800",3)
		@living_sensor = Onewire::DS_18B20.new("Living room temperature","Temperature in the living room","28.0AEA48010000","10",3)
		@upstairs_sensor = Onewire::DS_18B20.new("Upstairs temperature","Upstairs forest room","28.6A0B50010000","10",3)
		@basement_sensor = Onewire::DS_18S20.new("Basement temperature","In the sauna rest area","10.47BF24010800",3)
		@external_sensor = Onewire::DS_18B20.new("External temperature","On the northwestern external wall","28.CBD248010000","11",3)

		# Create the is_HW or valve movement proc for the floor PWM thermostats
		@is_HW_or_valve_proc = Proc.new {
		    determine_power_needed == "HW" or @moving_valves_required == true
		}

		
		# Create the value proc for the living floor thermostat.  Lambda is used because proc would also return the "return" command
		@living_floor_thermostat_valueproc = lambda { |sample_filter, target| 
      if $low_floor_temp_mode
        if sample_filter.value < -1
          return 0.2
        else
          return 0
        end
      else
   		  #	This is now fixed to : 0.2 @ 13 and 0.8 @ 6 Celsius above 13, zero, below 6 full power (+- of the sample_filter.value shifts curve)
    	  tmp = 1.31429 - (sample_filter.value-1) * 0.085714
    		tmp = 0 if tmp < 0.2 
    		tmp = 1 if tmp > 0.8 
    		return tmp
      end
      }


		# Create the value proc for the upstairs floor thermostat. Lambda is used because proc would also return the "return" command
		@upstairs_floor_thermostat_valueproc = lambda { |sample_filter, target|
      if $low_floor_temp_mode
        if sample_filter.value < -6
          return 0
        else
          return 0.2
        end
      else
        if !$upstairs_floor_unconditionally_on
#          # This is now fixed to : 0.2 @ 8 and 0.8 @ -2 Celsius above 8, zero, below -2 full power
#          tmp = 0.76 - sample_filter.value * 0.07
#          tmp = 0 if tmp < 0.2 
#          tmp = 1 if tmp > 0.8 
#          return tmp
      # This is now fixed to : 0.2 @ 13 and 0.8 @ 6 Celsius above 13, zero, below 6 full power (+- of the sample_filter.value shifts curve)
          tmp = 1.31429 - (sample_filter.value-1) * 0.085714
          tmp = 0 if tmp < 0.2 
          tmp = 1 if tmp > 0.8 
          return tmp
        else
          return 1
        end
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
		@living_thermostat = Symmetric_thermostat.new(@living_sensor,0.3,0.0,8)
		@HW_thermostat = Asymmetric_thermostat.new(@HW_sensor,2,2,0.0,1)
		@living_floor_thermostat = PwmThermostat.new(@external_sensor,10,@living_floor_thermostat_valueproc,@is_HW_or_valve_proc)
		@mode_thermostat = Symmetric_thermostat.new(@external_sensor,0.8,5.0,8)
		@upstairs_floor_thermostat = PwmThermostat.new(@external_sensor,10,@upstairs_floor_thermostat_valueproc,@is_HW_or_valve_proc)
		@upstairs_thermostat = Symmetric_thermostat.new(@upstairs_sensor,0.3,5.0,8)
    @basement_thermostat = PwmThermostat.new(@basement_sensor,10,@basement_thermostat_valueproc,@is_HW_or_valve_proc)

    #Technical targets must be set to allow PWM proc to detect changes
    @upstairs_floor_thermostat.set_target(0)
    @living_floor_thermostat.set_target(0)
    
		#	Create magnetic valves
		@basement_floor_valve = DelayedCloseMagneticValve.new("Basement floor valve","Contact 7 on main board","12.6E6B58000000","A",$do_tests)
		@basement_radiator_valve = DelayedCloseMagneticValve.new("Basement radiator valve","Contact 8 on main board","12.C92B1E000000","B",$do_tests)
		@living_floor_valve = DelayedCloseMagneticValve.new("Living level floor valve","In the living floor water distributor","05.5E0532000000",nil,$do_tests)
		@upstairs_floor_valve = DelayedCloseMagneticValve.new("Upstairs floor valve","In the upstairs water distributor","05.200232000000",nil,$do_tests)

		#	Create gas burner valves
		@gas_valve1 = Onewire::DS_2405.new("Gas burner valve 1","Contact 1 on main panel","05.CEE131000000",$do_tests)
		@gas_valve2 = Onewire::DS_2406.new("Gas burner valve 2","Contact 2 on main panel","12.C92B1E000000","A",$do_tests)

		#	Define the states of the furnace
		@state_Off = State.new("Off","Furnace switched off")
		@state_Preheat1 = State.new("Preheat1","Pre-heating in 1st gear")
		@state_Preheat2 = State.new("Preheat2","Pre-heating in 2nd gear")
		@state_Heat = State.new("Heat","Heating to the target temperature with PD controll")
		@state_Postheat = State.new("Postheat","Post ciculation with heating")
		@state_PostHW = State.new("PostHW","Post circulation w/o heating")

		# Create a Furnace PWM instance
		@furnace_pwm = Furnace_PWM.new(10.0,4.0)

		# PD contoller P Gain, D Gain
		@furnace_pd_controller = PD_controller.new(7,200)

		# Furnace analyzer - default sample buffer size: 6
    @furnace_analyzer = Furnace_analyzer.new
		
		# Jitter suppressed furnace temperature value with a buffer size of 10
		@filtered_furnace_temp = Filter.new(10)

		#	Set the caching mode of the owserver
		Onewire.set_caching("0","300","300","300","300","300")
	
		# Define the activating actions of each state
		# Activation actions for Off satate
		@state_Off.set_activate(
		proc {
			$debuglevel > 0 and puts "Activating \"Off\" state"

      # Extinguish all burners
      @gas_valve2.off
      @gas_valve1.off
						
			#	Turn off all pumps
			@radiator_pump.off
			@floor_pump.off
			@hidr_shift_pump.off
			@hot_water_pump.off
			
			#	Close all valves
			@basement_floor_valve.delayed_close
			@basement_radiator_valve.delayed_close
			@living_floor_valve.delayed_close
			@upstairs_floor_valve.delayed_close
			
		})

		# Activation actions for Heating 1st gear
		@state_Heat.set_activate(
		proc {
			$debuglevel > 0 and puts "Activating \"Heat\" state"

			# Reset filter and controller
			@filtered_furnace_temp.reset
			@furnace_pd_controller.reset
			@furnace_pwm.reset
			
			# Do not control pumps and valves	
			# Do not controll burners
		})

		# Activation actions for Post circulation heating
		@state_Postheat.set_activate(
		proc {
			$debuglevel > 0 and puts "Activating \"Postheat\" state"

      # Extinguish all burnrers
      @gas_valve2.off
      @gas_valve1.off

      # All radiator valves open
      @basement_radiator_valve.open

      #	Radiator pumps on
			@radiator_pump.on
			@floor_pump.off
			@hidr_shift_pump.on
			@hot_water_pump.off

			#	All floor valves closed
			@basement_floor_valve.delayed_close
			@living_floor_valve.delayed_close
			@upstairs_floor_valve.delayed_close
			
		})

		# Activation actions for Post circulation HW only
		@state_PostHW.set_activate(
		proc {
			$debuglevel > 0 and puts "Activating \"PostHW\" state"

      # Both burnrers off
      @gas_valve2.off
      @gas_valve1.off
			
			#	Only HW pump on
			@radiator_pump.off
			@floor_pump.off
			@hidr_shift_pump.off
			@hot_water_pump.on

			#	All valves are closed
			@basement_floor_valve.delayed_close
			@basement_radiator_valve.delayed_close
			@living_floor_valve.delayed_close
			@upstairs_floor_valve.delayed_close
			
		})


		#	Set the initial state
		if (initial_state == "Off")
			@state = @state_Off
			@state.activate

			@hist_state1 = @hist_state2 = @hist_state3 = @hist_state4 = @state
		else
			puts "Illegal initial state. Aborting."
			exit
		end
		
		#	Set the initial mode
		if initial_mode == "Off"
			@mode = @mode_Off
		elsif initial_mode == "HW"
			@mode = @mode_HW
		elsif initial_mode == "Heat"
			@mode = @mode_Heat
		else
			puts "Illegal initial mode. Aborting."
			exit
		end

		if !$do_tests
		  read_all_sensors
		end

		$debuglevel >0 and print "Furnace initialized initial state set to: ", @state.description, ", Initial mode set to: ",@mode.description,"\n"

	end

#	The function evaluating states and performing necessary
#	transitions basd on the current value of sensors
	def evaluate_state_change
		case @state.name
		# The evaluation of the Off state
		when "Off"
			if $debuglevel > 1
				puts "Evaluating Off state:"
				puts "\tIf need power then -> Heat"
        puts "\tIf furnace temp increases and furnace above HW temp + 7 C in HW mode then -> PostHW"
        puts "\tIf furnace temp increases and furnace above HW temp + 7 C not in HW mode then -> PostHeat"				
				puts "\tElse: Stay in Off state"
			end
			if determine_power_needed != false
				$debuglevel > 0 and puts "Decision: Need power changing state to Heat"
				$debuglevel > 1 and print "determine_power_needed: ",determine_power_needed,"\n"
				@state = @state_Heat
				@state.activate()
			elsif @HW_thermostat.temp + 7 < @furnace_temp and @furnace_analyzer.slope > 0 and @mode == @mode_HW
        $debuglevel > 0 and puts "Decision: Furnace temp increases and furnace above HW temp +7 C in HW mode changing state to PostHW"
        $debuglevel > 1 and print "determine_power_needed: ",determine_power_needed,"\n"
        @state = @state_PostHW
        @state.activate()
			elsif @HW_thermostat.temp + 7 < @furnace_temp and @furnace_analyzer.slope > 0
        $debuglevel > 0 and puts "Decision: Furnace temp increases and furnace above HW temp + 7 C not in HW mode changing state to Postheat"
        $debuglevel > 1 and print "determine_power_needed: ",determine_power_needed,"\n"
        @state = @state_Postheat
        @state.activate()
			else
				$debuglevel > 0 and puts "Decision: No power requirement - not changing state"
			end

		when "Heat"
			if $debuglevel > 1
				puts "Evaluating Heat state:"
				puts "\tControl valves and pumps based on measured temperatures"
				puts "\tControl burners to maintain target furnace temperature"
				puts "\tIf not need power anymore then -> Postheat or PostHW based on operating mode"
			end 
			if $debuglevel > 0
				puts "Heat"
			end

			# Control valves and pumps based on measured temperatures
			control_pumps_and_valves()

			# Control burners to maintain target furnace temperature
			do_furnace_pd_control()

			# If not need power anymore then -> Postheat or PostHW
      if determine_power_needed == false and @mode == @mode_HW
        $debuglevel > 0 and puts "Decision: No more power needed in HW mode - changing state to PostHW"
        $debuglevel > 1 and print "determine_power_needed: ",determine_power_needed,"\n"
        @state = @state_PostHW
        @state.activate()
			elsif determine_power_needed == false
				$debuglevel > 0 and puts "Decision: No more power needed not in HW mode - changing state to Postheat"
				$debuglevel > 1 and print "determine_power_needed: ",determine_power_needed,"\n"
				@state = @state_Postheat
				@state.activate()
			end

		when "Postheat"
			if $debuglevel > 1
				puts "Evaluating Postheat state:"
				puts "\tIf Delta T on the Furnace drops below 5 C then -> Off"
				puts "\tIf need power is not false then -> Heat"
			end 

			# If Delta T on the Furnace drops below 5 C then -> Off
			if @furnace_temp - @return_temp < 5.0
				$debuglevel > 0 and puts "Decision: Delta T on the Furnace dropped below 5 C - changing state to Off"
				@state = @state_Off
				@state.activate()
			# If need power then -> Heat
			elsif determine_power_needed != false
				$debuglevel > 0 and puts "Decision: Need power not false - changing state to Heat"
				@state = @state_Heat
				@state.activate()
			end

		when "PostHW"
			if $debuglevel > 1
				puts "Evaluating PostHW state:"
				puts "\tIf Delta T on the Furnace drops below 5 C then -> Off"
        puts "\tIf Furnace temp below HW temp + 4 C then -> Off"
				puts "\tIf need power is not false then -> Heat"
			end 

			# If Delta T on the Furnace drops below 5 C then -> Off
			if @furnace_temp - @return_temp < 5.0
        $debuglevel > 0 and puts "Decision: Delta T on the Furnace dropped below 5 C - changing state to Off"
        @state = @state_Off
        @state.activate()
			# If Furnace temp below HW temp + 4 C then -> Off
      elsif @furnace_temp < @HW_thermostat.temp + 4 
          $debuglevel > 0 and puts "Decision: Furnace temp below HW temp + 4 C  - changing state to Off"
          @state = @state_Off
          @state.activate()        
      # If need power then -> Heat
			elsif determine_power_needed != false
				$debuglevel > 0 and puts "Decision: Need power not false - changing state to Heat"
				@state = @state_Heat
				@state.activate()
			end		
		end
	end

	def do_furnace_pd_control
		@filtered_furnace_temp.input_sample(@furnace_temp)
		error = @target_furnace_temp - @filtered_furnace_temp.value
		kWvalue_requested = @furnace_pd_controller.output(error)
		@furnace_pwm.set_value(kWvalue_requested)
		pwm_output = @furnace_pwm.output
		if $debuglevel > 1 
			print "\nPD_control: error= ",error,"\n"
			print "PD_control: kWvalue_requested= ",kWvalue_requested,"\n"
			print "PD_control: PWMvalue= ",@furnace_pwm.pWMvalue,"\n"
			print "PD_control: Cycle_length= ",@furnace_pwm.cycle_length,"\n"
			print "PD_control: pwm_output= ",pwm_output,"\n\n"
		end

		case pwm_output
		when 0
			@gas_valve2.off
			@gas_valve1.off    
		when 1
			@gas_valve2.off
			@gas_valve1.on
		when 2
			if @gas_valve1.state == "on"
			  @gas_valve2.on
			else
			  @gas_valve1.on
			  sleep(6)
			  @gas_valve2.on
			end
		end
	end

	def read_all_sensors
		@furnace_temp = @furnace_sensor.temp
    @furnace_analyzer.update(@furnace_temp)
		@HW_thermostat.update
		@return_temp = @return_sensor.temp
		@living_thermostat.update
		@upstairs_thermostat.update
	  @basement_thermostat.update
		@living_floor_thermostat.update
		@upstairs_floor_thermostat.update
		@mode_thermostat.update

	end

#	Read the temperature sensors
	def read_sensors
#	   Always read the temperature values of fast changing or important sensors
		@furnace_temp = @furnace_sensor.temp
    @furnace_analyzer.update(@furnace_temp)

#		Read the slower changing and less timing critical  sensors
		if @cycle % 4 == 0
			@HW_thermostat.update
		end

		if @cycle % 40 == 5 or @cycle % 40 == 15 or @cycle % 40 == 25 or @cycle % 40 == 36
			@return_temp = @return_sensor.temp
		end
		
#		Read the slowest changing sensors
		if @cycle % 40 == 2
			@living_thermostat.update
		end

		if @cycle % 40 == 14
			@upstairs_thermostat.update
		end

		if @cycle % 40 == 22
			@basement_thermostat.update
		end

		if @cycle % 40 == 34
			@living_floor_thermostat.update
			@upstairs_floor_thermostat.update
			@mode_thermostat.update
		end

	end
	
#	Read the target temperatures, determine targets and operating mode
	def determine_targets
#		Determine the target temperatures

		file = File.new("/usr/lib/furnacecontrol/target_living_temp","r")
		@living_thermostat.set_threshold(file.readline.to_f)
		file.close()

		file = File.new("/usr/lib/furnacecontrol/target_upstairs_temp","r")
		@upstairs_thermostat.set_threshold(file.readline.to_f)
		file.close()

		file = File.new("/usr/lib/furnacecontrol/target_basement_temp","r")
		@basement_thermostat.set_target(file.readline.to_f)
		file.close()

		file = File.new("/usr/lib/furnacecontrol/mode_threshold","r")
		@mode_thermostat.set_threshold(file.readline.to_f)
		file.close()

		file = File.new("/usr/lib/furnacecontrol/target_HW_temp","r")
		if @mode_thermostat.state == "on"
		     @HW_thermostat.set_threshold(file.readline.to_f)
		     @state.name !="Heat" and @mode = @mode_Heat
		     @HW_thermostat.set_histeresis(2,2)
		else
		     @HW_thermostat.set_threshold(file.readline.to_f-4.0)
		     @state.name !="Heat" and @mode = @mode_HW
		     @HW_thermostat.set_histeresis(2,2)
		end
		file.close()

		case determine_power_needed
		when "HW"
			@target_furnace_temp = 80.0

		when "Rad"
			@target_furnace_temp = -4.5/2.0*@living_floor_thermostat.temp+65.0
			if @target_furnace_temp > 80.0
				@target_furnace_temp = 80.0
			elsif @target_furnace_temp < 55.0
				@target_furnace_temp = 55.0
			end

		when "RadFloor"
			@target_furnace_temp = -4.5/2.0*@living_floor_thermostat.temp+65.0
			if @target_furnace_temp > 80.0
				@target_furnace_temp = 80.0
			elsif @target_furnace_temp < 55.0
				@target_furnace_temp = 55.0
			end
		
		when "Floor"
			@target_furnace_temp = 55.0

		when false
			@target_furnace_temp = 7.0

		end
	
	end

	
#	The main loop of the controller
	def operate
		@cycle = 0
		@state_history = Array.new(4,[@state.name,determine_power_needed])
		while(!$shutdown_requested) do
			$debuglevel > 0 and print "Measuring loop cycle: ",@cycle,"\n"

			if !$do_tests
        read_sensors
        determine_targets
			else
				apply_test_control
			end

			if $Onewire_Requires_Furnace_Restart
			  Onewire.set_caching("0","300","300","300","300","300")
			  @state = @state_Off
			  @state.activate

			  @state_history.shift
			  @state_history.push(["Off_by_Onewire_restart",determine_power_needed])

			  $Onewire_Requires_Furnace_Restart = false
			  $onewire_restart_log = true
			else
			  evaluate_state_change
			  if @moving_valves_required and @state.name == "Off"
			      do_magnetic_valve_movement
			      @moving_valves_required = false
			  end
			end

			# Record state history for 4 states
			if @state_history.last[0] != @state.name
			  @state_history.shift
			  @state_history.push([@state.name,determine_power_needed])
			end

#			Increment the cycle and reset it if 40 cycles is reached
			@cycle = 0 if @cycle % 40 == 0 
			@cycle = @cycle + 1

			$debuglevel >0 and print "Furnace temp: ",@furnace_temp,"\n";
			$debuglevel >0 and print "Return temp: ",@return_temp,"\n";
			$debuglevel >0 and print "HW temp: ",@HW_thermostat.temp,"\n";
			$debuglevel >0 and print "Need power: ",determine_power_needed,"\n\n";
			
			logging
			
# Check Move if time is between 11:00 and 11:15 in the morning
			if (((Time.now.to_i % (24*60*60))+ 60*60) > (10*60*60)) and
			 (((Time.now.to_i % (24*60*60))+ 60*60) < (10.25*60*60))
			    magnetic_valve_move_evaluation
			end
		end
    shutdown
	end


	def magnetic_valve_move_evaluation
	  @move_logfile = File.new("/var/log/furnace_valve_log","a+")
	  @move_logfile.seek(0,IO::SEEK_SET)
	  while (!@move_logfile.eof)
	    lastline = @move_logfile.readline
	  end 
    file = File.new("/usr/lib/furnacecontrol/magnetic_valve_movement_days","r") 
    seconds_between_move = file.readline.to_i * 24*60*60
    file.close()
# Move if moved later than the parameter
	  if lastline.to_i+seconds_between_move < Time.now.to_i and 
# And we are just after 10 o'clock
	    ((Time.now.to_i % (24*60*60))+ 60*60) > (10*60*60)
	      @moving_valves_required = true
	      $debuglevel >0 and print "Setting moving_valves_required to true\n";
	  end
	  @move_logfile.close
	end

	def do_magnetic_valve_movement
	  $debuglevel >0 and print "Moving valves\n";

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
	      
	      sleep 10
	      @radiator_pump.off
	      @floor_pump.off
	      sleep 2
	      @basement_floor_valve.close
	      @basement_radiator_valve.close
	      @living_floor_valve.close
	      @upstairs_floor_valve.close
	      sleep 1
	      repeat = repeat-1
	  end 
	  @move_logfile = File.new("/var/log/furnace_valve_log","a+")
	  @move_logfile.write(Time.now.to_s)
	  @move_logfile.write("\n")
	  @move_logfile.write(Time.now.to_i.to_s)
	  @move_logfile.write("\n")
	  @move_logfile.close
	end
	
	def logging
	  if @furnace_temp > $overheat_log_threshold or $logging_active or $control_logging or $onewire_restart_log
	    if !@logfile.respond_to?("write")
	      @logfile = File.new("/var/log/furnacecontrol","a")
	      @logfile.sync = true
	    end

	    if @furnace_temp > $overheat_log_threshold
	      do_logging(@logfile,"Overheat")
	    elsif $logging_active
	      do_logging(@logfile,"Normal logging")
	    elsif $control_logging
	      do_logging(@logfile,"Control logging")
	    elsif $onewire_restart_log
	      do_logging(@logfile,"Onewire restart logging")
	      $onewire_restart_log = false
	    end
	  else
	    if @logfile.respond_to?("close")
	      @logfile.close()
	      @logfile = nil
	    end
	  end
	end
	
	def do_logging(logfile,logging_reason)
		if logging_reason == "Overheat" or logging_reason == "Normal logging"
			@logfile.write("\nLOGITEM BEGIN @"+Time.now.asctime+"\n")
			@logfile.write("Logging reason: "+logging_reason+"\n")	
			@logfile.write("Active state: "+@state.name+"\n")
			sth=""
      @state_history.each {|e| sth+= ") => ("+e*","}
      @logfile.write("State and entering determine_power_needed history : "+sth[5,1000]+")\n")
      @logfile.write("Furnace temperature: "+@furnace_temp.to_s+"\n")
      @logfile.write("Return water temperature: "+@return_temp.to_s+"\n")
      @logfile.write("Delta T on the Furnace: "+(@furnace_temp-@return_temp).to_s+"\n")
      @logfile.write("Target furnace temp: "+@target_furnace_temp.to_s+"\n")

      @logfile.write("HW temperature: "+@HW_thermostat.temp.to_s+"\n")
      @logfile.write("External temperature: "+@living_floor_thermostat.temp.to_s+"\n")

      @logfile.write("Need power: "+determine_power_needed.to_s+"\n")
      @logfile.write("Operating mode: "+@mode.description+"\n")

      @logfile.write("HW pump: "+@hot_water_pump.state+"\n")
      @logfile.write("Radiator pump: "+@radiator_pump.state+"\n")
      @logfile.write("Floor pump: "+@floor_pump.state+"\n")
      @logfile.write("Hidr shift pump: "+@hidr_shift_pump.state+"\n")
      
      @logfile.write("Living floor PWM value: "+@living_floor_thermostat.value.to_s+"\n")
      @logfile.write("Living floor valve: "+@living_floor_valve.state+"\n")
      @logfile.write("Living floor thermostat status: "+@living_floor_thermostat.state+"\n")

      @logfile.write("Upstairs floor PWM value: "+@upstairs_floor_thermostat.value.to_s+"\n")
      @logfile.write("Upstairs floor valve: "+@upstairs_floor_valve.state+"\n")
      @logfile.write("Upstairs floor thermostat status: "+@upstairs_floor_thermostat.state+"\n")
	    
	    @logfile.write("Basement PWM value: "+@basement_thermostat.value.to_s+"\n")
      @logfile.write("Basement valve: "+@basement_floor_valve.state+"\n")
      @logfile.write("Basement thermostat status: "+@basement_thermostat.state+"\n")

      @logfile.write("Basement temperature: "+@basement_thermostat.temp.to_s+"\n")
	    @logfile.write("Living temperature: "+@living_thermostat.temp.to_s+"\n")
      @logfile.write("Upstairs temperature: "+@upstairs_thermostat.temp.to_s+"\n")

      @logfile.write("Burner1: "+@gas_valve1.state+"\n")
      @logfile.write("Burner2: "+@gas_valve2.state+"\n")
      @logfile.write("LOGITEM END\n")
		elsif logging_reason == "Control logging"
			if	@gas_valve1.state == "off" and @gas_valve2.state == "off"
				input = 0
			elsif @gas_valve1.state == "on" and @gas_valve2.state == "off"
				input = 1
			else
				input = 2
			end
			if determine_power_needed == "Floor"
				type = "F"
			elsif determine_power_needed == "RadFloor"
				type = "RF"
			else
				type = "HW"
			end
			@logfile.write(type+","+(Time.now.to_f-1231360000).to_s+","+input.to_s+","+@furnace_temp.to_s+"\n")
		 elsif logging_reason == "Onewire restart logging"
			@logfile.write("\nLOGITEM BEGIN @"+Time.now.asctime+"\n")
			@logfile.write("Logging reason: "+logging_reason+"\n")	
			@logfile.write("Active state: "+@state.name+"\n")
			@logfile.write("Exception message: "+$Owserver_Exception.inspect+"\n")
			@logfile.write("State history : ("+@hist_state4.name+")->("+@hist_state3.name+")->("+@hist_state2.name+")->("+@hist_state1.name+")->("+@state.name+")\n")
			@logfile.write("LOGITEM END\n")
		end
	end

	# This function controls valves and pumps during heating by evaluating the required power
	def control_pumps_and_valves
		$debuglevel >1 and puts "Controlling valves and pumps"
		if @furnace_temp > $overheat_log_threshold # Overheat protection
      # All valves are open
      @basement_floor_valve.open
      @basement_radiator_valve.open
      @living_floor_valve.open
      @upstairs_floor_valve.open

      # All pumps except HW pump on
			@radiator_pump.on
			@floor_pump.on
			@hidr_shift_pump.on
			@hot_water_pump.off
		elsif @furnace_temp > 42.0 # If furnace above 42C turn heating on
			$debuglevel > 0 and puts "Outgoing water above 42C turning on pumps and valves"
			case determine_power_needed
			when "HW" # Only Hot water supplies on
				#	Only HW pump on
				@radiator_pump.off
				@floor_pump.off
				@hidr_shift_pump.off
				@hot_water_pump.on

				#	All valves are closed
				@basement_floor_valve.delayed_close
				@basement_radiator_valve.delayed_close
				@living_floor_valve.delayed_close
				@upstairs_floor_valve.delayed_close

			when "Rad" # Only Radiator pumps on

				@basement_floor_valve.delayed_close
				@living_floor_valve.delayed_close
				@upstairs_floor_valve.delayed_close

				#  decide on basement radiator valve
				if @basement_thermostat.state == "on"
					@basement_radiator_valve.open
				else
					@basement_radiator_valve.delayed_close
				end

				# Control basic pumps
				@hidr_shift_pump.on
				@hot_water_pump.off

				# Radiator pump on
				@radiator_pump.on

				# Floor heating off
				@floor_pump.off


			when "RadFloor"
				# decide on living floor valve based on external temperature
				if @living_floor_thermostat.state == "on"
					@living_floor_valve.open
				else
					@living_floor_valve.delayed_close
				end

				# decide on upstairs floor valve based on external temperature
				if @upstairs_floor_thermostat.state == "on"
					@upstairs_floor_valve.open
				else
					@upstairs_floor_valve.delayed_close
				end

				# decide on basement valves based on basement temperature
				if @basement_thermostat.state == "on"
					@basement_radiator_valve.open
					@basement_floor_valve.open
				else
					@basement_radiator_valve.delayed_close
					@basement_floor_valve.delayed_close
				end

				@hidr_shift_pump.on
				@hot_water_pump.off
			
				# Floor heating on
				@floor_pump.on

				# Radiator pump on
				@radiator_pump.on
			
			when "Floor"
				# decide on living floor valve based on external temperature
				if @living_floor_thermostat.state == "on"
					@living_floor_valve.open
				else
					@living_floor_valve.delayed_close
				end

				# decide on upstairs floor valve based on external temperature
				if @upstairs_floor_thermostat.state == "on"
					@upstairs_floor_valve.open
				else
					@upstairs_floor_valve.delayed_close
				end
				
				# decide on basement valve based on basement temperature
				if @basement_thermostat.state == "on"
					@basement_floor_valve.open
				else
					@basement_floor_valve.delayed_close
				end

				@basement_radiator_valve.delayed_close

				@hidr_shift_pump.on
				@hot_water_pump.off
				@radiator_pump.off

				# Floor heating on
				@floor_pump.on

			end
		elsif @furnace_temp < 40.0 # All pumps and valves off - Histeresis
			$debuglevel > 0 and puts "Outgoing water below 42C turning off pumps and valves"
			#	All pumps off
			@radiator_pump.off
			@floor_pump.off
			@hidr_shift_pump.off
			@hot_water_pump.off
			#	All valves are closed
			@basement_floor_valve.delayed_close
			@basement_radiator_valve.delayed_close
			@living_floor_valve.delayed_close
			@upstairs_floor_valve.delayed_close
		end
	end

	# This function tells what kind of  power is needed
	def determine_power_needed
		if @moving_valves_required
			return false
		elsif @mode != @mode_Off and @HW_thermostat.state == "on"
			# Power needed for hot water - overrides Heat power need
			return "HW"
		elsif @mode == @mode_Heat and (@upstairs_thermostat.state == "on" or \
			@living_thermostat.state == "on" ) and \
			@living_floor_thermostat.state == "off" and \
			@upstairs_floor_thermostat.state == "off" and \
			@basement_thermostat.state == "off"
			# Power needed for heating
			return "Rad"
		elsif @mode == @mode_Heat and (@upstairs_thermostat.state == "on" or \
			@living_thermostat.state == "on" ) and \
			(@living_floor_thermostat.state == "on" or \
			 @upstairs_floor_thermostat.state == "on" or \
		         @basement_thermostat.state == "on")
			# Power needed for heating and floor heating
			return "RadFloor"
		elsif @living_floor_thermostat.state == "on" or \
			@upstairs_floor_thermostat.state == "on" or \
			@basement_thermostat.state == "on"
			# Power needed for floor heating only
			return "Floor"
		else
			# No power needed
			return false
		end
	end

#	Walk through states to test the state machine
	def apply_test_control()

		Thread.pass

		sleep(0.5)

		file = File.new("furnace_temp","r")
		@furnace_temp = file.readline.to_f
		file.close()

		file = File.new("return_temp","r")
		@return_temp = file.readline.to_f
		file.close()

		file = File.new("HW_temp","r")
		@HW_thermostat.test_update(file.readline.to_f)
		file.close()

		file = File.new("living_temp","r")
		@living_thermostat.test_update(file.readline.to_f)
		file.close()

		file = File.new("upstairs_temp","r")
		@upstairs_thermostat.test_update(file.readline.to_f)
		file.close()

		file = File.new("basement_temp","r")
#		@basement_thermostat.test_update(file.readline.to_f)
		@basement_thermostat.update
		file.close()

		file = File.new("external_temp","r")
		@living_floor_thermostat.test_update(file.readline.to_f)
		file.close()

		file = File.new("external_temp","r")
		@upstairs_floor_thermostat.test_update(file.readline.to_f)
		file.close()
		
		file = File.new("target_living_temp","r")
		@living_thermostat.set_threshold(file.readline.to_f)
		file.close()

		file = File.new("target_upstairs_temp","r")
		@upstairs_thermostat.set_threshold(file.readline.to_f)
		file.close()

		file = File.new("target_basement_temp","r")
		@basement_thermostat.set_threshold(file.readline.to_f)
		file.close()

		file = File.new("target_HW_temp","r")
		@HW_thermostat.set_threshold(file.readline.to_f)
		file.close()

		file = File.new("target_furnace_temp","r")
		@target_furnace_temp = file.readline.to_f
		file.close()

		if @test_cycle_cnt == 0
		end

		print "Living floor PWM thermostat value: "
		puts @living_floor_thermostat.value
		print "Living floor PWM thermostat state: "
		puts @living_floor_thermostat.state
		puts "Power needed: " + determine_power_needed.to_s
		print "\n"

		@test_cycle_cnt += 1
	
	end

	def shutdown
		@state = @state_Off
		@state.activate
		puts " Shutting down."
		command="rm -f "+$pidpath
		system(command)
	end

end



Thread.current["thread_name"] = "Main thread"

RobustThread.logger = Logger.new('/var/log/furnace_daemonlog')

Signal.trap("TERM") do
  $shutdown_requested = true
end

pid = fork do
  main_rt = RobustThread.new(:label => "Main daemon thread") do

    Signal.trap("HUP", "IGNORE")
  
    if ARGV[0] != nil
      $pidpath = ARGV[0]
    else
      $pidpath = "/var/run/furnacecontrol.pid"
    end
    pidfile=File.new($pidpath,"w")
    pidfile.write(Process.pid.to_s)
    pidfile.close
  
    #	Set the initial state
    furnace = State_Machine.new("Off","Heat")
    # furnace.test_walk_states

    furnace.operate
  end
end
Process.detach pid
