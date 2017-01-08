require "/usr/local/lib/boiler_controller/Buscomm"
require "/usr/local/lib/boiler_controller/Globals"
require "rubygems"
require "robustthread"

module BusDevice
  class DeviceBase

    COMM_SPEED = Buscomm::COMM_SPEED_9600_H

    # Delayed close magnetic valve close delay in secs
    DELAYED_CLOSE_VALVE_DELAY = 2
    def initialize
      (defined? @@comm_interface) == nil and @@comm_interface = Buscomm.new($config[:bus_master_address], $config[:serial_device], COMM_SPEED)
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
          $app_logger.trace("Check round started")
          @@check_process_mutex.synchronize {actual_check_list = @@check_list.dup}
          $app_logger.trace("Element count in checkround: #{actual_check_list.size}")
          el_count = 1
          actual_check_list.each do |element|
            $app_logger.trace("Element # #{el_count} checking launched")
            el_count +=1

            # Distribute checking each object across the check period evenly
            actual_check_list.size > 0 and sleep $config[:check_period_interval_sec] / actual_check_list.size
            sleep 1
            $app_logger.trace("Bus device consistency checker process: Checking '#{element[:Obj].name}'")

            # Check if the checker process is accessible
            if (defined? element[:Proc]) != nil

              # Call the checker process and capture result
              result = element[:Proc].call
              $app_logger.trace("Bus device consistency checker process: Checkresult for '#{element[:Obj].name}': #{result}")
            else

              # Log that the checker process is not accessible, and forcibly unregister it
              $app_logger.error("Bus device consistency checker process: Check method not defined for: '#{element.inspect}' Deleting from list")
              @@check_process_mutex.synchronize {@@check_list.delete(element)}
            end

            # Just log the result - the checker process itself is expected to take the appropriate action upon failure
            $app_logger.trace("Bus device consistency checker process: Check method result for: '#{element[:Obj].name}': #{result}")
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
      write_device(0) if !@dry_run
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
      retval = false
      @state_semaphore.synchronize do
        if @state != :on
          @state = :on
          write_device(1) == :Success and $app_logger.trace("Succesfully turned Switch '#{@name}' on.")
          retval = true
        end
      end # of state semaphore sync
      return retval
    end

    # Turn the device off
    def off
      retval = false
      @state_semaphore.synchronize do
        if @state != :off
          @state = :off
          write_device(0) == :Success and $app_logger.trace("Succesfully turned Switch '#{@name}' off.")
          retval = true
        end
      end # of state semaphore sync
      return retval
    end

    private

    # Write the value of the parameter to the device on the bus
    # Request fatal shutdown on unrecoverable communication error
    def write_device(value)
      if !@dry_run
        begin
          retval = @@comm_interface.send_message(@slave_address,Buscomm::SET_REGISTER,@register_address.chr+value.chr)
          $app_logger.trace("Sucessfully written #{value} to register '#{@name}'")
        rescue MessagingError => e
          retval = e.return_message
          $app_logger.fatal("Unrecoverable communication error on bus, writing '#{@name}' ERRNO: #{retval[:Return_code]} - #{Buscomm::RESPONSE_TEXT[retval[:Return_code]]}")
          $shutdown_reason = Globals::FATAL_SHUTDOWN
          return :Failure
        end
      else
        $app_logger.trace("Dry run - writing #{value} to register '#{@name}'")
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
        retry_count = 1

        @state_semaphore.synchronize do

          # Check what value the device knows of itself
          retval = @@comm_interface.send_message(@slave_address,Buscomm::READ_REGISTER,@register_address.chr)

          # Temp variable state_val holds the server side state binary value
          @state == :on ? state_val = 1 : state_val = 0
          while retval[:Content][Buscomm::PARAMETER_START].ord != state_val and retry_count <= CHECK_RETRY_COUNT

            errorstring = "Mismatch during check between expected switch with Name: '"+@name+"' Location: '"+@location+"'\n"
            errorstring += "Known state: #{state_val} device returned state: #{retval[:Content][Buscomm::PARAMETER_START].ord}\n"
            errorstring += "Trying to set device to the known state - attempt no: #{retry_count}"

            $app_logger.error(errorstring)

            # Try setting the server side known state to the device
            retval = @@comm_interface.send_message(@slave_address,Buscomm::SET_REGISTER,@register_address.chr+state_val.chr)

            # Re-read the device value to see if write was succesful
            retval = @@comm_interface.send_message(@slave_address,Buscomm::READ_REGISTER,@register_address.chr)

            # Sleep more and more - hoping that the mismatch error resolves itself
            sleep retry_count*0.23
            retry_count += 1
          end
        end #of state semaphore sync
        # Bail out if comparison/resetting trial fails CHECK_RETRY_COUNT times
        if retry_count >= CHECK_RETRY_COUNT
          $app_logger.fatal("Unable to recover "+@name+" device mismatch. Potential HW failure - bailing out")
          $shutdown_reason = Globals::FATAL_SHUTDOWN
          check_result = :Failure
        end

      rescue MessagingError => e
        # Log the messaging error
        retval = e.return_message
        $app_logger.fatal("Unrecoverable communication error on bus communicating with '"+@name+"' ERRNO: #{retval[:Return_code]} - #{Buscomm::RESPONSE_TEXT[retval[:Return_code]]}")

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
      return false unless @delayed_close_semaphore.try_lock
      retval = false
      @modification_semaphore.synchronize do
        Thread.new do
          sleep DELAYED_CLOSE_VALVE_DELAY
          retval = parent_off
        end
      end
      @delayed_close_semaphore.unlock
      return retval
    end

    def on
      retval = false
      @modification_semaphore.synchronize { retval = parent_on }
      return retval
    end

    def open
      on
    end
    # End of class DelayedCloseMagneticValve
  end

  class PulseSwitch < DeviceBase
    attr_accessor :dry_run
    attr_reader :state, :name, :slave_address, :location

    STATE_READ_PERIOD=1
    def initialize(name, location, slave_address, register_address, dry_run)
      @name = name
      @slave_address = slave_address
      @location = location
      @register_address = register_address
      @dry_run = dry_run
      @movement_active = false

      # Wait until the device becomes inactive to establish a known state
      $app_logger.debug("Waiting until Pulse Switch'"+@name+"' becomes inactive")
      wait_until_inactive
      start_state_reader_thread if @state == :active
    end

    # Turn the device on
    def pulse_block(duration)
      write_device(duration) == :Success and $app_logger.trace("Succesfully started pulsing Switch '"+@name+"'")
      sleep STATE_READ_PERIOD
      wait_until_inactive
    end

    def active?
      return @movement_active
    end

    private

    def wait_until_inactive
      while read_device == 1
        @movement_active = true
        sleep STATE_READ_PERIOD
      end
      @movement_active = false
    end

    def read_device
      if !@dry_run
        begin
          retval = @@comm_interface.send_message(@slave_address,Buscomm::READ_REGISTER,@register_address.chr)
          $app_logger.trace("Sucessfully read device '#{@name}' address #{@register_address}")
        rescue MessagingError => e
          retval = e.return_message
          $app_logger.fatal("Unrecoverable communication error on bus, reading '#{@name}' ERRNO: #{retval[:Return_code]} - #{Buscomm::RESPONSE_TEXT[retval[:Return_code]]}")
          $shutdown_reason = Globals::FATAL_SHUTDOWN
          return 0
        end

        return retval[:Content][Buscomm::PARAMETER_START].ord

      else
        $app_logger.debug("Dry run - reading device '#{@name}' address #{@register_address}")
        return 0
      end
    end

    # Write the value of the parameter to the device on the bus
    # Request fatal shutdown on unrecoverable communication error
    def write_device(value)
      if !@dry_run
        begin
          retval = @@comm_interface.send_message(@slave_address,Buscomm::SET_REGISTER,@register_address.chr+value.chr)
          $app_logger.trace("Sucessfully written #{value} to pulse switch '#{@name}'")
        rescue MessagingError => e
          retval = e.return_message
          $app_logger.fatal("Unrecoverable communication error on bus, writing '#{@name}' ERRNO: #{retval[:Return_code]} - #{Buscomm::RESPONSE_TEXT[retval[:Return_code]]}")
          $shutdown_reason = Globals::FATAL_SHUTDOWN
          return :Failure
        end
      else
        $app_logger.trace("Dry run - writing #{value} to register '#{@name}'")
      end
      return :Success
    end
    #End of class PulseSwitch
  end

  class TempSensor < DeviceBase
    attr_reader :name, :slave_address, :location
    attr_accessor :mock_temp

    ONE_BIT_TEMP_VALUE = 0.0625
    TEMP_BUS_READ_TIMEOUT = 2
    ONEWIRE_TEMP_FAIL = -1295.0625 #"" << 0x0f.chr << 0xaf.chr * ONE_BIT_TEMP_VALUE
    DEFAULT_TEMP = 85.0
    UNREALISTIC_TEMP_DIFF_THRESHOLD = 15
    def initialize(name, location, slave_address, register_address, dry_run, mock_temp, debug=false)
      @name = name
      @slave_address = slave_address
      @location = location
      @register_address = register_address
      @dry_run = dry_run
      @mock_temp = mock_temp
      @debug = debug

      @temp_reader_mutex = Mutex.new

      @delay_timer = Globals::TimerSec.new(TEMP_BUS_READ_TIMEOUT,"Temp Sensor Delay timer: "+@name)

      super()

      # Perform initial temperature read
      @delay_timer.reset
      initial_temp = read_temp
      if initial_temp != nil
        @lasttemp = initial_temp
      else
        @lasttemp = DEFAULT_TEMP
      end
      @skipped_temp_values = 0
    end

    def temp
      @temp_reader_mutex.synchronize do
        if @delay_timer.expired?
          temp_tmp = read_temp
          # Skip out of bounds and sudden power-on reset values
          if temp_tmp < -55 or temp_tmp > 125 or
          ((temp_tmp-@lasttemp).abs > UNREALISTIC_TEMP_DIFF_THRESHOLD and temp_tmp == DEFAULT_TEMP)
            @skipped_temp_values += 1
          else
            @lasttemp = temp_tmp
            @delay_timer.reset
            @skipped_temp_values = 0
          end
          if @skipped_temp_values > 0
            $app_logger.debug("Skipped #{@skipped_temp_values} samples at #{@name}")
            $app_logger.debug("Last skipped temp value is: #{temp_tmp}")
          end
        end
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
        $app_logger.trace("Succesful read from temp register of '"+@name+"'")

        # Calculate temperature value from the data returned
        temp = "" << retval[:Content][Buscomm::PARAMETER_START] << retval[:Content][Buscomm::PARAMETER_START+1]
        $app_logger.info("Low level HW "+@name+" value: "+temp.unpack("H*")[0]) if @debug
        return temp.unpack("s")[0]*ONE_BIT_TEMP_VALUE

      rescue MessagingError => e
        # Log the messaging error
        retval = e.return_message
        $app_logger.fatal("Unrecoverable communication error on bus reading '"+@name+"' ERRNO: #{retval[:Return_code]} - #{Buscomm::RESPONSE_TEXT[retval[:Return_code]]} Device return code: #{retval[:DeviceResponseCode]}")

        # Signal the main thread for fatal error shutdown
        $shutdown_reason = Globals::FATAL_SHUTDOWN
        return @lasttemp
      end
    end

    # End of Class definition TempSensor
  end

  class WaterTempBase < DeviceBase
    attr_accessor :dry_run
    attr_reader :value, :name, :slave_address, :location, :temp_required

    CHECK_RETRY_COUNT = 5
    VOLATILE = 0x01
    NON_VOLATILE = 0x00
    def initialize(name, location, slave_address, register_address, dry_run, init_temp=20.0)
      @name = name
      @slave_address = slave_address
      @location = location
      @register_address = register_address
      @dry_run = dry_run
      @state_semaphore = Mutex.new

      super()

      # Set non-volatile wiper value to 0x00 to ensure that we are safe when the device wakes up ucontrolled
      write_device(wiper_lookup(init_temp),NON_VOLATILE)

      # Initialize the volatile value to the device
      @value = wiper_lookup(init_temp)
      @temp_required = init_temp
      write_device(@value, VOLATILE)
      register_check_process
    end

    # Set the required water temp value
    def set_water_temp(temp_requested)
      @state_semaphore.synchronize do
        @temp_required = temp_requested
        value_requested = wiper_lookup(temp_requested)

        # Only write new value if it differs from the actual value to spare bus time
        if value_requested != @value
          @value = value_requested
          write_device(@value, VOLATILE)
          $app_logger.debug(@name+" set to value #{@value} meaning water temperature #{@temp_required.round(2)} C")
        end
      end # of state semaphore synchronize
    end

    # Get the target water temp
    def get_target
      return @temp_required
    end

    private

    # Write the value of the parameter to the device on the bus
    # Bail out on unrecoverable communication error
    def write_device(value, is_volatile)
      if !@dry_run
        begin
          if value != 0xff
            @@comm_interface.send_message(@slave_address,Buscomm::SET_REGISTER,@register_address.chr+0x00.chr+value.chr+is_volatile.chr)
          else
            @@comm_interface.send_message(@slave_address,Buscomm::SET_REGISTER,@register_address.chr+0x01.chr+0xff.chr+is_volatile.chr)
          end
          $app_logger.trace("Dry run - writing "+value.to_s(16)+" to wiper register with is_volatile flag set to #{is_volatile} in '#{@name}'")
        rescue MessagingError => e
          # Get the returned message
          retval = e.return_message

          # Log the error and bail out
          $app_logger.fatal("Unrecoverable communication error on bus, writing '#{@name}' ERRNO: #{retval[:Return_code]} - #{Buscomm::RESPONSE_TEXT[retval[:Return_code]]}")
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
        retry_count = 1

        @state_semaphore.synchronize do
          # Check what value the device knows of itself
          retval = @@comm_interface.send_message(@slave_address,Buscomm::READ_REGISTER,@register_address.chr+VOLATILE.chr)

          # Loop until there is no difference or retry_count is reached
          while retval[:Content][Buscomm::PARAMETER_START].ord != @value and retry_count <= CHECK_RETRY_COUNT

            errorstring = "Mismatch during check between expected water_temp: '"+@name+"' Location: '"+@location+"'\n"
            errorstring += "Known value: #{@value} device returned state: #{retval[:Content][Buscomm::PARAMETER_START].ord}\n"
            errorstring += "Trying to set device to the known state - attempt no: #{retry_count}"

            $app_logger.error(errorstring)

            # Retry setting the server side known state on the device
            retval = @@comm_interface.send_message(@slave_address,Buscomm::SET_REGISTER,@register_address.chr+0x00.chr+@value.chr+VOLATILE.chr)
            # Re-read the result to see if the device side update was succesful
            retval = @@comm_interface.send_message(@slave_address,Buscomm::READ_REGISTER,@register_address.chr+VOLATILE.chr)

            # Sleep more each round hoping for a resolution
            sleep retry_count*0.23
            retry_count += 1
          end
        end # of state semaphore synchronize
        # Bail out if comparison/resetting trial fails CHECK_RETRY_COUNT times
        if retry_count >= CHECK_RETRY_COUNT
          $app_logger.fatal("Unable to recover "+@name+" device value mismatch. Potential HW failure - bailing out")
          $shutdown_reason = Globals::FATAL_SHUTDOWN
          check_result = :Failure
        end

      rescue Exception => e
        # Log the messaging error
        if e.class  == MessagingError
          retval = e.return_message
          $app_logger.fatal("Unrecoverable communication error on bus communicating with '"+@name+"' ERRNO: #{retval[:Return_code]} - #{Buscomm::RESPONSE_TEXT[retval[:Return_code]]}")
        else
          $app_logger.fatal("Exception: #{e.inspect}")
          $app_logger.fatal("Exception: #{e.backtrace}")
        end

        # Signal the main thread for fatal error shutdown
        $shutdown_reason = Globals::FATAL_SHUTDOWN
        check_result = :Failure
      end
      return check_result
    end

    #End of class WaterTempBase
  end

  class HeatingWaterTemp < WaterTempBase
    def initialize(name, location, slave_address, register_address, dry_run, init_temp=20.0)
      @lookup_curve =
      Globals::Polycurve.new([
        [28,0x00],
        [34,0x96],
        [37,0xa4],
        [40,0xb0],
        [44,0xc0],
        [53.6,0xd2], # [49,0xd0] 
        # ---------    [54,0xd8],
        [62,0xe0], # 58 -> 62
        [71,0xe8], # 65 -> 71
        [74,0xeb], # 69 -> 74
        [76,0xf0], # 74 -> 76
        [80,0xf4],
        [84,0xf8],
        [85,0xff]])
      super(name, location, slave_address, register_address, dry_run, init_temp)
    end

    protected

    def wiper_lookup(temp_value)
      return @lookup_curve.value(temp_value)
    end
    # End of class HeatingWaterTemp
  end

  class HWWaterTemp < WaterTempBase
    def initialize(name, location, slave_address, register_address, dry_run, shift = 0, init_temp=65.0)
      @lookup_curve =
      Globals::Polycurve.new([
        [21.5,0x00], # 11.3k
        [23.7,0x10], # 10.75k
        [24.7,0x20], # 10.21k
        [26.0,0x30], # 9.65k
        [27.1,0x40], # 9.13k
        [28.5,0x50], # 8.58k
        [29.5,0x60], # 8.2k
        [31.8,0x70], # 7.47k
        [33.8,0x80], # 6.89k
        [36.0,0x90], # 6.33k
        [38.25,0xa0], # 5.77k
        [40.5,0xb0], # 5.19k
        [43.7,0xc0], # 4.61k
        [45.1,0xd0], # 4.3k
        [51.4,0xe0], # 3.45k
        [56.1,0xf0], # 2.86k
        [61.5,0xfe], # 2.32k
        [62.6,0xff] # 2.28k
      ], shift)
      super(name, location, slave_address, register_address, dry_run, init_temp)
    end

    protected

    def wiper_lookup(temp_value)
      return @lookup_curve.value(temp_value)
    end
    # End of class HWWaterTemp
  end

end #End of module BusDevice
