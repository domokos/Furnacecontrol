
require "./Buscomm"
require "./Globals"
require "rubygems"
require "robustthread"

module BusDevice

  class DeviceBase
  
    CHECK_INTERVAL_PERIOD_SEC = 60
    MASTER_ADDRESS = 1
    SERIALPORT_NUM = "/dev/pts/0" #0
    COMM_SPEED = Buscomm::COMM_SPEED_9600_H
    
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
          @@check_process_mutex.synchronize {actual_check_list = @@check_list.dup}
          actual_check_list.each do |element|
            # Distribute checking each object across CHECK_INTERVAL_PERIOD_SEC evenly 
            sleep CHECK_INTERVAL_PERIOD_SEC / actual_check_list.size
            $logger.debug("Bus device consistency checker process: Checking '"+element[:Obj].name+"'")
              
            # Check if the checker process is accessible 
            if (defined? element[:Proc]) != nil
              
              # Call the checker process and capture result
              result = element[:Proc].call 
              $logger.debug("Bus device consistency checker process: Checkresult for '"+element[:Obj].name+"':"+result.to_s)
            else
              
              # Log that the checker process is not accessible, and forcibly unregister it
              $logger.error("Bus device consistency checker process: Check method not defined for: '"+element.inspect+" Deleting from list")
              @@check_process_mutex.synchronize {@@check_list.delete(element)}
            end
            
            # Just log the result - the checker process itself is expected to take the appropriate action upon failure
            $logger.debug("Bus device consistency checker process: Check method result for: '"+element[:Obj].name+": "+result.to_s)
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
          write_device(1) == :Success and $logger.debug("Succesfully turned Switch '"+@name+"' on.")
        end
      end
    end
  
    # Turn the device off
    def off
      @state_semaphore.synchronize do
        if @state != :off
          @state = :off
          write_device(1) == :Success and $logger.debug("Succesfully turned Switch '"+@name+"' off.")
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
          $logger.debug("Sucessfully written "+value.to_s+" to register '"+@name+"'")
        rescue MessagingError => e
          retval = e.return_message
          $logger.fatal("Unrecoverable communication error on bus, writing '"+@name+"' ERRNO: "+retval[:Return_code].to_s+" - "+Buscomm::RESPONSE_TEXT[retval[:Return_code]])
          $shutdown_requested = Globals::FATAL_SHUTDOWN
          return :Failure
        end
      else
        $logger.debug("Dry run - writing "+value.to_s+" to register '"+@name+"'")
      end
      return :Success
    end

    alias :register_at_super :register_checker
    
    # Thread to periodically check switch value consistency 
    # with the state stored in the class
    def register_check_process
      register_at_super(self.method(:check_process),self)
    end
    
    def check_process
      check_result = :Success
      
      begin
        # Check what value the device knows of itself
        retval = @@comm_interface.send_message(@slave_address,Buscomm::READ_REGISTER,@register_address.chr)

        retry_count = 1
        
        # Temp variable state_val holds the server side state binary value
        @state == :on ? state_val = 1 : state_val = 0
        while retval[:Content][Buscomm::PARAMETER_START] != state_val or retry_count <= CHECK_RETRY_COUNT

          $logger.error("Mismatch during check between expected switch with Name: '"+@name+"' Location: '"+@location+"'") 
          $logger.error("Known state: "+state_val.to_s+" device returned state: "+ret[:Content][Buscomm::PARAMETER_START]) 
          $logger.error("Trying to set device to the known state - attempt no: "+ retry_count.to_s)

          # Try setting the server side known state to the device
          retval = @@comm_interface.send_message(@slave_address,Buscomm::SET_REGISTER,@register_address.chr+state_val.chr)

          retry_count += 1
          # Sleep more and more - hoping that the mismatch error resolves itself
          sleep retry_count * 0.23
        end

        # Bail out if comparison/resetting trial fails CHECK_RETRY_COUNT times
        if retry_count > CHECK_RETRY_COUNT
          $logger.fatal("Unable to recover device mismatch. Potential HW failure - bailing out")
          $shutdown_requested = Globals::FATAL_SHUTDOWN
          check_result = :Failure
        end

      rescue MessagingError => e
        # Log the messaging error
        retval = e.return_message
        $logger.fatal("Unrecoverable communication error on bus communicating with '"+@name+"' ERRNO: "+retval[:Return_code].to_s+" - "+Buscomm::RESPONSE_TEXT[retval[:Return_code]])
          
        # Signal the main thread for fatal error shutdown
        $shutdown_requested = Globals::FATAL_SHUTDOWN
        check_result = :Failure
      end

      return check_result
     end

  #End of class Switch    
  end

 
  class TempSensor < DeviceBase
    attr_reader :name, :slave_address, :location
  

    def initialize(name, location, slave_address, register_address, min_communication_delay)
      @name = name
      @slave_address = slave_address 
      @location = location
      @register_address = register_address
      @dry_run = dry_run
  
      @delay_timer = Timer.new(min_communication_delay,"Temp Sensor Delay timer: "+@name)
           
      super()
      
      # Perform initial temperature read
      @delay_timer.reset
      @lasttemp = read_temp
    end
         
    def temp
      if !@delay_timer.expired?
        return @lasttemp
      else
        @lasttemp = read_temp
        @delay_timer.reset
        return @lasttemp
      end
    end
    
    private
    def read_temp
      begin
        # Reat the register on the bus
        retval = @@comm_interface.send_message(@slave_address,Buscomm::READ_REGISTER,@register_address.chr)
        $logger.debug("Succesful read from temp register of '"+@name+"'")
        
        # Calculate temperature value from the data returned
        temp = "" << retval[:Content][Buscomm::PARAMETER_START] << retval[:Content][Buscomm::PARAMETER_START+1]
        return temp.unpack("s")[0]*0.0625

      rescue MessagingError => e
        # Log the messaging error
        retval = e.return_message
        $logger.fatal("Unrecoverable communication error on bus reading '"+@name+"' ERRNO: "+retval[:Return_code].to_s+" - "+Buscomm::RESPONSE_TEXT[retval[:Return_code]])
          
        # Signal the main thread for fatal error shutdown
        $shutdown_requested = Globals::FATAL_SHUTDOWN
        return 40.0
      end
    end

  # End of Class definition TempSensor  
  end
    
class WaterTemp < DeviceBase
   attr_accessor :dry_run
   attr_reader :value, :name, :slave_address, :location, :temp_reqired
 
   CHECK_RETRY_COUNT = 5
   
   def initialize(name, location, slave_address, register_address, dry_run)
     @name = name
     @slave_address = slave_address 
     @location = location
     @register_address = register_address
     @dry_run = dry_run
 
     super()
     
     # Set non-volatile wiper value to 0x00 to ensure that we are safe when the device wakes up ucontrolled
     write_value(0x00,0x00)
     
     # Initialize the volatile value to the device
     @value = 0x00
     @temp_reqired = 27.0 
     write_value(@value,0x01)
     register_check_process
   end
     
   # Set the required water temp value            
   def set_water_temp(temp_requested)
     @value = wiper_lookup(temp_requested)
     @temp_reqired = temp_requested
     write_device(@value,0x00)
     $logger.info("Water temperature wiper rheostat set to value "+@value.to_s+" requiring water temperature "+@temp_required.to_s+" C on '"+@name+"'")
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
     elsif temp_value > 34
       return ((0xa4-0x96) / (37.0-34.0) * (temp_value-34.0) + 0x96).round
     elsif temp_value == 34
       return 0x96
     else
       return 0x80
     end
   end
   
  # 0x10 - <27 C
  # 0x60 - >26 C - turns on from 26 30?

   
   # Write the value of the parameter to the device on the bus
   # Bail out on unrecoverable communication error
   def write_value(value, is_volatile)
     if !@dry_run
       begin
         @@comm_interface.send_message(@slave_address,Buscomm::SET_REGISTER,@register_address.chr+0x00.chr+value.chr+is_volatile.chr)
         $logger.debug("Dry run - writing "+value.to_s(16)+" to wiper register with is_volatile flag set to "+is_volatile+" in '"+@name+"'")
       rescue MessagingError => e
         retval = e.return_message
         $logger.fatal("Unrecoverable communication error on bus, writing '"+@name+"' ERRNO: "+retval[:Return_code].to_s+" - "+Buscomm::RESPONSE_TEXT[retval[:Return_code]])
         $shutdown_fatal_requested = Globals::FATAL_SHUTDOWN
       end
     end
   end

   alias :register_at_super :register_checker
   
   # Thread to periodically check switch value consistency 
   # with the state stored in the class
   def register_check_process
     register_at_super(self.method(:check_process),self)
   end
   
   def check_process
     check_result = "Success"
     # Check what value the device knows of itself
     retval = @@comm_interface.send_message(@slave_address,Buscomm::READ_REGISTER,@register_address.chr+0x00.chr)
     
     # Exception is raised inside the block for fatal errors
     begin
       raise "Unrecoverable communication error on bus, reading '"+@name+"' ERRNO: "+retval[:Return_code].to_s+" - "+Buscomm::RESPONSE_TEXT[retval[:Return_code]] if retval[:Return_code] != Buscomm::NO_ERROR
       retry_count = 1
       
       # Loop until there is no difference or retry_count is reached
       while retval[:Content][Buscomm::PARAMETER_START].ord != @value

         $logger.error("Mismatch during check between expected water_temp: '"+@name+"' Location: "+@location)
         $logger.error("Known value: "+@value.to_s+" device returned state: "+ret[:Content][Buscomm::PARAMETER_START]) 
         $logger.error("Trying to set device to the known state - attempt no: "+ retry_count.to_s)

         # Bail out if resetting trial fails more than CHECK_RETRY_COUNT times
         raise "Unable to recover device mismatch. Potential HW failure - bailing out" if retry_count > CHECK_RETRY_COUNT
         
         # Retry setting the server side known state on the device
         retval = @@comm_interface.send_message(@slave_address,Buscomm::SET_REGISTER,@register_address.chr+0x00.chr+@value.chr+0x00.chr)
         raise "Unrecoverable communication error on bus writing '"+@name+"', ERRNO: "+retval[:Return_code].to_s+" - "+Buscomm::RESPONSE_TEXT[retval[:Return_code]] if retval[:Return_code] != Buscomm::NO_ERROR
       
         retry_count += 1
       end
     rescue Exception => e
       # Fatal error bail out
       $logger.fatal(e.inspect)

       # Signal the main thread for shutdown
       $shutdown_fatal_requested = true
       check_result = "Failure"
     end
     return check_result
    end

 #End of class WaterTemp    
 end
 
#End of module BusDevice
end
