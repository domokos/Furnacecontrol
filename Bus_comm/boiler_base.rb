
require "./Buscomm"
require "rubygems"
require "robustthread"

 module Globals
   WARN = {"Logtext"=>"WARN","Ord"=>1}
   INFO = {"Logtext"=>"INFO","Ord"=>2}
   ERROR = {"Logtext"=>"ERROR","Ord"=>3}

   class Logger
     def initialize(logfile)
       if File.exists?(logfile) and !File.writable?(logfile)
         puts 'Startup error: Logfile "'+logfile+'" is not writable. Aborting.'
         exit
       end
       
       begin
         @logfile = File.new(logfile,"a")
         @logfile.write(Time.now.strftime("%Y-%m-%d %H:%M:%S.%L")+" [INFO] Boiler controller startup\n")
       rescue Exception => e
         puts "Startup error: Logfile cannot be opened. "+e.message+" Aborting."
         exit
       end
       @logfile.sync = true
       @log_semaphore = Mutex.new
     end
         
     def log(level,entry)
       @log_semaphore.synchronize do
         @logfile.write(Time.now.strftime("%Y-%m-%d %H:%M:%S.%L") + " [" + level["Logtext"] + "] " + entry + "\n")
       end
     end
     
     def close
       @logile.close
     end
    #End of Class Logger
   end
   
   $logger=Logger.new('./boiler_controller.log')
# End of module Globals          
 end

module BusDevice

  class DeviceBase
  
    def initialize ()
      
      STDOUT.sync = true
      
      #Parameters
      @serialport_num = 0
      @comm_speed = Buscomm::COMM_SPEED_9600_H
      @master_address = 1
      
      @@comm_interface = Buscomm.new(@master_address,@serialport_num,@comm_speed)
    end
    
  #End of class DeviceBase  
  end
    
  class Switch
    attr_accessor :name, :id, :location, :do_tests
    attr_reader :state
  
    def initialize(name, location, master_id, slave_id, register_address, do_tests)
      @name = name
      @master_id = master_id
      @slave_id = slave_id 
      @location = location
      @register_address = register_address
      @do_tests = do_tests
      
      @state = read_state
  
      !@do_tests and off
    end
  
    def close  
      off
    end
  
    def open
      on
    end
    
    def read_state
    
    end
    
    def write_state
  
      
    end
      
    def on
      if @state != "on"
        !@do_tests and write_path("1")
        @state = "on"
      end
    end
  
    def off
      if @state != "off"
        !@do_tests and write_path("0")
        @state = "off"
      end
    end
  #End of class Switch  
  end
  
#End of module BusDevice
end
