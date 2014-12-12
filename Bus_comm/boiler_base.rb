
require "/usr/local/lib/boiler_controller/Buscomm"
require "/usr/local/lib/boiler_controller/Globals"
require "rubygems"
require "robustthread"

module BusDevice

  class DeviceBase
  
    CHECK_INTERVAL_PERIOD_SEC = 200
    MASTER_ADDRESS = 1
    SERIALPORT_NUM = 0
    COMM_SPEED = Buscomm::COMM_SPEED_9600_H

    # Delayed close magnetic valve close delay in secs
    DELAYED_CLOSE_VALVE_DELAY = 2
        
    def initialize
      (defined? @@comm_interface) == nil and @@comm_interface = Buscomm.new(MASTER_ADDRESS, SERIALPORT_NUM, COMM_SPEED)
      (defined? @@check_process_mutex) == nil and @@check_process_mutex = Mutex.new
      (defined? @@check_list) == nil and @@check_list = []
    end

    def register_checker(process,object)
      @@check_process_mutex.synchronize {@@check_list.push({:Proc=>process,:Obj=>object})}
      start_check_process
    end
        
    def start_check_process
      (defined? @@check_process) != nil and return
      actual_check_list = []
      @@check_process = Thread.new do
        while true
          $app_logger.debug("Check round started")
          @@check_process_mutex.synchronize {actual_check_list = @@check_list.dup}
          $app_logger.debug("Element count in checkround: "+actual_check_list.size.to_s)
          el_count = 1
          actual_check_list.each do |element|
            $app_logger.debug("Element # "+el_count.to_s+" checking launched")
            el_count +=1

            # Distribute checking each object across CHECK_INTERVAL_PERIOD_SEC evenly 
            actual_check_list.size > 0 and sleep CHECK_INTERVAL_PERIOD_SEC / actual_check_list.size
            sleep 1
            $app_logger.debug("Bus device consistency checker process: Checking '"+element[:Obj].name+"'")
              
            # Check if the checker process is accessible 
            if (defined? element[:Proc]) != nil
              
              # Call the checker process and capture result
              result = element[:Proc].call 
              $app_logger.debug("Bus device consistency checker process: Checkresult for '"+element[:Obj].name+"': "+result.to_s)
            else
              
              # Log that the checker process is not accessible, and forcibly unregister it
              $app_logger.error("Bus device consistency checker process: Check method not defined for: '"+element.inspect+" Deleting from list")
              @@check_process_mutex.synchronize {@@check_list.delete(element)}
            end
            
            # Just log the result - the checker process itself is expected to take the appropriate action upon failure
            $app_logger.debug("Bus device consistency checker process: Check method result for: '"+element[:Obj].name+"': "+result.to_s)
          end
        end
       end
     end
       
  #End of Class definition DeviceBase  
  end
    
  class Switch < DeviceBase
    attr_accessor :dry_run
    attr_reader :state, :name, :slave_address, :location
  
    CHECK_RETRY_COUNT = 5
    
    def initialize(name, location, slave_address, register_address, dry_run)
      @name = name
      @slave_address = slave_address 
      @location = location
      @register_address = register_address
      @dry_run = dry_run
      @state_semaphore = Mutex.new
      
      super()
      
      # Initialize state to off
      @state = :off
      !@dry_run and write_device(0)
      register_check_process
    end
      
    def close  
      off
    end
  
    def open
      on
    end

    # Turn the device on           
    def on
      @state_semaphore.synchronize do
        if @state != :on
          @state = :on
          write_device(1) == :Success and $app_logger.debug("Succesfully turned Switch '"+@name+"' on.")
        end
      end
    end
  
    # Turn the device off
    def off
      @state_semaphore.synchronize do
        if @state != :off
          @state = :off
          write_device(0) == :Success and $app_logger.debug("Succesfully turned Switch '"+@name+"' off.")
        end
      end
    end
    
    private

    # Write the value of the parameter to the device on the bus
    # Request fatal shutdown on unrecoverable communication error
    def write_device(value)
      if !@dry_run 
        begin
          retval = @@comm_interface.send_message(@slave_address,Buscomm::SET_REGISTER,@register_address.chr+value.chr)
          $app_logger.debug("Sucessfully written "+value.to_s+" to register '"+@name+"'")
        rescue MessagingError => e
          retval = e.return_message
          $app_logger.fatal("Unrecoverable communication error on bus, writing '"+@name+"' ERRNO: "+retval[:Return_code].to_s+" - "+Buscomm::RESPONSE_TEXT[retval[:Return_code]])
          $shutdown_reason = Globals::FATAL_SHUTDOWN
          return :Failure
        end
      else
        $app_logger.debug("Dry run - writing "+value.to_s+" to register '"+@name+"'")
      end
      return :Success
    end

    alias_method :register_at_super, :register_checker
    
    # Thread to periodically check switch value consistency 
    # with the state stored in the class
    def register_check_process
      register_at_super(self.method(:check_process),self)
    end
    
    def check_process

      # Initialize variable holding return value
      check_result = :Success

      # Do not check if in DryRun
      return check_result if @dry_run

      begin
        # Check what value the device knows of itself
        retval = @@comm_interface.send_message(@slave_address,Buscomm::READ_REGISTER,@register_address.chr)

        retry_count = 1

        # Temp variable state_val holds the server side state binary value
        @state == :on ? state_val = 1 : state_val = 0
        while retval[:Content][Buscomm::PARAMETER_START] != state_val or retry_count <= CHECK_RETRY_COUNT

          $app_logger.error("Mismatch during check between expected switch with Name: '"+@name+"' Location: '"+@location+"'") 
          $app_logger.error("Known state: "+state_val.to_s+" device returned state: "+ret[:Content][Buscomm::PARAMETER_START]) 
          $app_logger.error("Trying to set device to the known state - attempt no: "+ retry_count.to_s)

          # Try setting the server side known state to the device
          retval = @@comm_interface.send_message(@slave_address,Buscomm::SET_REGISTER,@register_address.chr+state_val.chr)

          # Re-read the device value to see if write was succesful
          retval = @@comm_interface.send_message(@slave_address,Buscomm::READ_REGISTER,@register_address.chr)

          # Sleep more and more - hoping that the mismatch error resolves itself
          sleep retry_count*0.23
          retry_count += 1
        end

        # Bail out if comparison/resetting trial fails CHECK_RETRY_COUNT times
        if retry_count >= CHECK_RETRY_COUNT
          $app_logger.fatal("Unable to recover "+@name+" device mismatch. Potential HW failure - bailing out")
          $shutdown_reason = Globals::FATAL_SHUTDOWN
          check_result = :Failure
        end

      rescue MessagingError => e
        # Log the messaging error
        retval = e.return_message
        $app_logger.fatal("Unrecoverable communication error on bus communicating with '"+@name+"' ERRNO: "+retval[:Return_code].to_s+" - "+Buscomm::RESPONSE_TEXT[retval[:Return_code]])
          
        # Signal the main thread for fatal error shutdown
        $shutdown_reason = Globals::FATAL_SHUTDOWN
        check_result = :Failure
      end

      return check_result
     end

  #End of class Switch    
  end

  # This Magnetic valve closes with a delay to decrease shockwawe effects in the system
  class DelayedCloseMagneticValve < Switch
    
    def initialize(name, location, slave_address, register_address, dry_run)
      super(name, location, slave_address, register_address, dry_run)
      @delayed_close_semaphore = Mutex.new
      @modification_semaphore = Mutex.new
    end
    
    alias_method :parent_off, :off
    alias_method :parent_on, :on
    
    def delayed_close
      return unless @delayed_close_semaphore.try_lock
      @modification_semaphore.synchronize do
        Thread.new do
          sleep DELAYED_CLOSE_VALVE_DELAY
          parent_off
        end
      end
      @delayed_close_semaphore.unlock
    end
 
    def on
      @modification_semaphore.synchronize do
        parent_on
      end
    end
    def open
      on
    end
    
     
  # End of class DelayedCloseMagneticValve
  end
  
  class TempSensor < DeviceBase
    attr_accessor :mock_temp 
    attr_reader :name, :slave_address, :location

    ONE_BIT_TEMP_VALUE = 0.0625
    TEMP_BUS_READ_TIMEOUT = 2
     
    def initialize(name, location, slave_address, register_address, dry_run, mock_temp)
      @name = name
      @slave_address = slave_address 
      @location = location
      @register_address = register_address
      @dry_run = dry_run
      @mock_temp = mock_temp
  
      @delay_timer = Globals::TimerSec.new(TEMP_BUS_READ_TIMEOUT,"Temp Sensor Delay timer: "+@name)
                 
      super()
      
      # Perform initial temperature read
      @delay_timer.reset
      @lasttemp = read_temp
    end
         
    def temp
      if @delay_timer.expired?
        @lasttemp = read_temp
        @delay_timer.reset
      end
      return @lasttemp
    end
    
    private
    def read_temp
      # Return if in testing
      return @mock_temp if @dry_run 

      begin
        # Reat the register on the bus
        retval = @@comm_interface.send_message(@slave_address,Buscomm::READ_REGISTER,@register_address.chr)
        $app_logger.debug("Succesful read from temp register of '"+@name+"'")
        
        # Calculate temperature value from the data returned
        temp = "" << retval[:Content][Buscomm::PARAMETER_START] << retval[:Content][Buscomm::PARAMETER_START+1]
        return temp.unpack("s")[0]*ONE_BIT_TEMP_VALUE

      rescue MessagingError => e
        # Log the messaging error
        retval = e.return_message
        $app_logger.fatal("Unrecoverable communication error on bus reading '"+@name+"' ERRNO: "+retval[:Return_code].to_s+" - "+Buscomm::RESPONSE_TEXT[retval[:Return_code]])
          
        # Signal the main thread for fatal error shutdown
        $shutdown_reason = Globals::FATAL_SHUTDOWN
        return @lasttemp
      end
    end

  # End of Class definition TempSensor  
  end
    
  class WaterTemp < DeviceBase
   attr_accessor :dry_run
   attr_reader :value, :name, :slave_address, :location, :temp_required
 
   CHECK_RETRY_COUNT = 5
   VOLATILE = 0x01
   NON_VOLATILE = 0x00
   
   def initialize(name, location, slave_address, register_address, dry_run)
     @name = name
     @slave_address = slave_address 
     @location = location
     @register_address = register_address
     @dry_run = dry_run
 
     super()
     
     # Set non-volatile wiper value to 0x00 to ensure that we are safe when the device wakes up ucontrolled
     write_device(0x00,VOLATILE)
     
     # Initialize the volatile value to the device
     @value = 0x00
     @temp_required = 20.0 
     write_device(@value, NON_VOLATILE)
     register_check_process
   end
     
   # Set the required water temp value            
   def set_water_temp(temp_requested)
     @temp_required = temp_requested
     value_requested = wiper_lookup(temp_requested)
     
     # Only write new value if it differs from the actual value to spare bus time 
     if value_requested != @value
       @value = value_requested
       write_device(@value, VOLATILE)
       $app_logger.info("Water temperature wiper rheostat set to value "+@value.to_s+" requiring water temperature "+@temp_required.to_s+" C on '"+@name+"'")
     end
   end
   
   private

   def wiper_lookup(temp_value)
     if temp_value>84
       return 0xff
     elsif temp_value == 84
       return 0xf8
     elsif temp_value > 80
       return ((0xf8-0xf4) / (84.0-80.0) * (temp_value-80.0) + 0xf4).round
     elsif temp_value == 80
       return 0xf4
     elsif temp_value > 74
       return ((0xf4-0xf0) / (80.0-74.0) * (temp_value-74.0) + 0xf0).round
     elsif temp_value == 74
       return 0xf0
     elsif temp_value > 69
       return ((0xf0-0xeb) / (74.0-69.0) * (temp_value-69.0) + 0xeb).round
     elsif temp_value == 69
       return 0xeb
     elsif temp_value > 65
       return ((0xeb-0xe8) / (69.0-65.0) * (temp_value-65.0) + 0xe8).round
     elsif temp_value == 65
       return 0xe8
     elsif temp_value > 58
       return ((0xe8-0xe0) / (65.0-58.0) * (temp_value-58.0) + 0xe0).round
     elsif temp_value == 58
       return 0xe0
     elsif temp_value > 54
       return ((0xe0-0xd8) / (58.0-54.0) * (temp_value-54.0) + 0xd8).round
     elsif temp_value == 54
       return 0xd8
     elsif temp_value > 49
       return ((0xd8-0xd0) / (54.0-49.0) * (temp_value-49.0) + 0xd0).round
     elsif temp_value == 49
       return 0xd0
     elsif temp_value > 44
       return ((0xd0-0xc0) / (49.0-44.0) * (temp_value-44.0) + 0xc0).round
     elsif temp_value == 44
       return 0xc0
     elsif temp_value > 40
       return ((0xc0-0xb0) / (44.0-40.0) * (temp_value-40.0) + 0xb0).round
     elsif temp_value == 40
       return 0xb0
     elsif temp_value > 37
       return ((0xb0-0xa4) / (40.0-37.0) * (temp_value-37.0) + 0xa4).round
     elsif temp_value == 37
       return 0xa4
     elsif temp_value > 35
       return ((0xa4-0x96) / (37.0-35.0) * (temp_value-35.0) + 0x96).round
     elsif temp_value == 35
       return 0x96
     else
       return 0x00
     end
   end
   
  # 0x10 - <27 C
  # 0x60 - >26 C - turns on from 26 30?

   
   # Write the value of the parameter to the device on the bus
   # Bail out on unrecoverable communication error
   def write_device(value, is_volatile)
     if !@dry_run
       begin
         @@comm_interface.send_message(@slave_address,Buscomm::SET_REGISTER,@register_address.chr+0x00.chr+value.chr+is_volatile.chr)
         $app_logger.debug("Dry run - writing "+value.to_s(16)+" to wiper register with is_volatile flag set to "+is_volatile.to_s+" in '"+@name+"'")
       rescue MessagingError => e
         # Get the returned message
         retval = e.return_message
         
         # Log the error and bail out
         $app_logger.fatal("Unrecoverable communication error on bus, writing '"+@name+"' ERRNO: "+retval[:Return_code].to_s+" - "+Buscomm::RESPONSE_TEXT[retval[:Return_code]])
         $shutdown_reason = Globals::FATAL_SHUTDOWN
       end
     end
   end

   alias_method :register_at_super, :register_checker
   
   # Thread to periodically check switch value consistency 
   # with the state stored in the class
   def register_check_process
     register_at_super(self.method(:check_process),self)
   end
   
   def check_process
     # Preset variable holding check return value
     check_result = :Success
     
     # Return success if a dry run is required
     return check_result if @dry_run
      
     # Exception is raised inside the block for fatal errors
     begin
       # Check what value the device knows of itself
       retval = @@comm_interface.send_message(@slave_address,Buscomm::READ_REGISTER,@register_address.chr+0x00.chr)

       retry_count = 1   
       # Loop until there is no difference or retry_count is reached
       while retval[:Content][Buscomm::PARAMETER_START].ord != @value or retry_count <= CHECK_RETRY_COUNT

         $app_logger.error("Mismatch during check between expected water_temp: '"+@name+"' Location: "+@location)
         $app_logger.error("Known value: "+@value.to_s+" device returned state: "+ret[:Content][Buscomm::PARAMETER_START]) 
         $app_logger.error("Trying to set device to the known state - attempt no: "+ retry_count.to_s)
         
         # Retry setting the server side known state on the device
         retval = @@comm_interface.send_message(@slave_address,Buscomm::SET_REGISTER,@register_address.chr+0x00.chr+@value.chr+0x00.chr)
         # Re-read the result to see if the device side update was succesful
         retval = @@comm_interface.send_message(@slave_address,Buscomm::READ_REGISTER,@register_address.chr+0x00.chr)
         
         # Sleem more each round hoping for a resolution
         sleep retry_count*0.23                
         retry_count += 1
       end
       
       # Bail out if comparison/resetting trial fails CHECK_RETRY_COUNT times
       if retry_count >= CHECK_RETRY_COUNT
         $app_logger.fatal("Unable to recover "+@name+" device value mismatch. Potential HW failure - bailing out")
         $shutdown_reason = Globals::FATAL_SHUTDOWN
         check_result = :Failure
       end
       
     rescue Exception => e
       # Log the messaging error
       retval = e.return_message
       $app_logger.fatal("Unrecoverable communication error on bus communicating with '"+@name+"' ERRNO: "+retval[:Return_code].to_s+" - "+Buscomm::RESPONSE_TEXT[retval[:Return_code]])
          
       # Signal the main thread for fatal error shutdown
       $shutdown_reason = Globals::FATAL_SHUTDOWN
       check_result = :Failure
     end
     return check_result
    end

 #End of class WaterTemp    
 end
 
#End of module BusDevice
end


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
      @content.size > @size and @content.shift
      @dirty = true
      return value
    end
  
    def value
      if @dirty
        @content.size == 0 and return nil
        sum = 0
        @content.each do
          |element|
          sum += element
        end
        @value = sum.to_f / @content.size
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
      update
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
    def initialize(sensor,down_histeresis,up_histeresis,threshold,filtersize)
      @sensor = sensor
      @up_histeresis = up_histeresis
      @down_histeresis = down_histeresis
      @threshold = threshold
      @sample_filter = Filter.new(filtersize)
      if sensor.temp >= @threshold
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
  # passed to it as the last argument. The reference function should return true at times, when the PWM thermostat
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
      
      
      self.class.start_pwm_thread if defined?(@@pwm_thread) == nil
    end
  
    def self.start_pwm_thread
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
            # are to be on as in this case furnace effort is spent on HW or valve movement rather
            # than on heating. This actually is only good for the active thermostats as others
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
  
    def PwmThermostat.finalize
      @@pwm_thread.kill
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
  end
  
  
end