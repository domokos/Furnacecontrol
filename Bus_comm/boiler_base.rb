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
          $app_logger.trace("Check round started")
          @@check_process_mutex.synchronize {actual_check_list = @@check_list.dup}
          $app_logger.trace("Element count in checkround: "+actual_check_list.size.to_s)
          el_count = 1
          actual_check_list.each do |element|
            $app_logger.trace("Element # "+el_count.to_s+" checking launched")
            el_count +=1

            # Distribute checking each object across CHECK_INTERVAL_PERIOD_SEC evenly
            actual_check_list.size > 0 and sleep CHECK_INTERVAL_PERIOD_SEC / actual_check_list.size
            sleep 1
            $app_logger.trace("Bus device consistency checker process: Checking '"+element[:Obj].name+"'")

            # Check if the checker process is accessible
            if (defined? element[:Proc]) != nil

              # Call the checker process and capture result
              result = element[:Proc].call
              $app_logger.trace("Bus device consistency checker process: Checkresult for '"+element[:Obj].name+"': "+result.to_s)
            else

              # Log that the checker process is not accessible, and forcibly unregister it
              $app_logger.error("Bus device consistency checker process: Check method not defined for: '"+element.inspect+" Deleting from list")
              @@check_process_mutex.synchronize {@@check_list.delete(element)}
            end

            # Just log the result - the checker process itself is expected to take the appropriate action upon failure
            $app_logger.trace("Bus device consistency checker process: Check method result for: '"+element[:Obj].name+"': "+result.to_s)
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
      @state_semaphore.synchronize do
        if @state != :on
          @state = :on
          write_device(1) == :Success and $app_logger.trace("Succesfully turned Switch '"+@name+"' on.")
        end
      end
    end

    # Turn the device off
    def off
      @state_semaphore.synchronize do
        if @state != :off
          @state = :off
          write_device(0) == :Success and $app_logger.trace("Succesfully turned Switch '"+@name+"' off.")
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
          $app_logger.trace("Sucessfully written "+value.to_s+" to register '"+@name+"'")
        rescue MessagingError => e
          retval = e.return_message
          $app_logger.fatal("Unrecoverable communication error on bus, writing '"+@name+"' ERRNO: "+retval[:Return_code].to_s+" - "+Buscomm::RESPONSE_TEXT[retval[:Return_code]])
          $shutdown_reason = Globals::FATAL_SHUTDOWN
          return :Failure
        end
      else
        $app_logger.trace("Dry run - writing "+value.to_s+" to register '"+@name+"'")
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

          errorstring = "Mismatch during check between expected switch with Name: '"+@name+"' Location: '"+@location+"'\n"
          errorstring += "Known state: "+state_val.to_s+" device returned state: "+ret[:Content][Buscomm::PARAMETER_START].ord.to_s+"\n"
          errorstring += "Trying to set device to the known state - attempt no: "+retry_count.to_s

          $app_logger.error(errorstring)

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
      @modification_semaphore.synchronize { parent_on }
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
      write_device(duration) == :Success and $app_logger.debug("Succesfully started pulsing Switch '"+@name+"'")
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
          $app_logger.debug("Sucessfully read device '"+@name+"' address "+@register_address.to_s)
        rescue MessagingError => e
          retval = e.return_message
          $app_logger.fatal("Unrecoverable communication error on bus, reading '"+@name+"' ERRNO: "+retval[:Return_code].to_s+" - "+Buscomm::RESPONSE_TEXT[retval[:Return_code]])
          $shutdown_reason = Globals::FATAL_SHUTDOWN
          return 0
        end

        return retval[:Content][Buscomm::PARAMETER_START]

      else
        $app_logger.debug("Dry run - reading device '"+@name+"' address "+@register_address.to_s)
        return 0
      end
    end

    # Write the value of the parameter to the device on the bus
    # Request fatal shutdown on unrecoverable communication error
    def write_device(value)
      if !@dry_run
        begin
          retval = @@comm_interface.send_message(@slave_address,Buscomm::SET_REGISTER,@register_address.chr+value.chr)
          $app_logger.trace("Sucessfully written "+value.to_s+" to pulse switch '"+@name+"'")
        rescue MessagingError => e
          retval = e.return_message
          $app_logger.fatal("Unrecoverable communication error on bus, writing '"+@name+"' ERRNO: "+retval[:Return_code].to_s+" - "+Buscomm::RESPONSE_TEXT[retval[:Return_code]])
          $shutdown_reason = Globals::FATAL_SHUTDOWN
          return :Failure
        end
      else
        $app_logger.trace("Dry run - writing "+value.to_s+" to register '"+@name+"'")
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
    ONEWIRE_TEMP_FAIL = "" << 0x0f.chr << 0xaf.chr
    DEFAULT_TEMP = 85.0
    def initialize(name, location, slave_address, register_address, dry_run, mock_temp, debug=false)
      @name = name
      @slave_address = slave_address
      @location = location
      @register_address = register_address
      @dry_run = dry_run
      @mock_temp = mock_temp
      @debug = debug

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
    end

    def temp
      if @delay_timer.expired?
        temp_tmp = read_temp
        @lasttemp = temp_tmp unless temp_tmp == ONEWIRE_TEMP_FAIL or temp_tmp < -5 or temp_tmp > 85
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
        $app_logger.trace("Succesful read from temp register of '"+@name+"'")

        # Calculate temperature value from the data returned
        temp = "" << retval[:Content][Buscomm::PARAMETER_START] << retval[:Content][Buscomm::PARAMETER_START+1]
        $heating_logger.info("Low level HW "+@name+" value: "+temp.unpack("H*")[0]) if @debug
        return temp.unpack("s")[0]*ONE_BIT_TEMP_VALUE

      rescue MessagingError => e
        # Log the messaging error
        retval = e.return_message
        $app_logger.fatal("Unrecoverable communication error on bus reading '"+@name+"' ERRNO: "+retval[:Return_code].to_s+" - "+Buscomm::RESPONSE_TEXT[retval[:Return_code]]+" Device return code: "+retval[:DeviceResponseCode].to_s)

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
        $app_logger.debug(@name+" set to value "+@value.to_s+" meaning water temperature "+@temp_required.to_s+" C")
      end
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
          $app_logger.trace("Dry run - writing "+value.to_s(16)+" to wiper register with is_volatile flag set to "+is_volatile.to_s+" in '"+@name+"'")
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

          errorstring = "Mismatch during check between expected water_temp: '"+@name+"' Location: '"+@location+"'\n"
          errorstring += "Known value: "+@value.to_s+" device returned state: "+ret[:Content][Buscomm::PARAMETER_START]+"\n"
          errorstring += "Trying to set device to the known state - attempt no: "+ retry_count.to_s

          $app_logger.error(errorstring)

          # Retry setting the server side known state on the device
          retval = @@comm_interface.send_message(@slave_address,Buscomm::SET_REGISTER,@register_address.chr+0x00.chr+@value.chr+0x00.chr)
          # Re-read the result to see if the device side update was succesful
          retval = @@comm_interface.send_message(@slave_address,Buscomm::READ_REGISTER,@register_address.chr+0x00.chr)

          # Sleep more each round hoping for a resolution
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

    #End of class WaterTempBase
  end

  class HeatingWaterTemp < WaterTempBase
    def initialize(name, location, slave_address, register_address, dry_run)
      @lookup_curve =
      Globals::Polycurve.new([
        [33,0x00],
        [34,0x96],
        [37,0xa4],
        [40,0xb0],
        [44,0xc0],
        [49,0xd0],
        [54,0xd8],
        [58,0xe0],
        [65,0xe8],
        [69,0xeb],
        [74,0xf0],
        [80,0xf4],
        [84,0xf8],
        [85,0xff]])
      super(name, location, slave_address, register_address, dry_run)
    end

    protected

    def wiper_lookup(temp_value)
      return @lookup_curve.value(temp_value)
    end
    # End of class HeatingWaterTemp
  end

  class HWWaterTemp < WaterTempBase
    def initialize(name, location, slave_address, register_address, dry_run, shift = 0)
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
      super(name, location, slave_address, register_address, dry_run)
    end

    protected

    def wiper_lookup(temp_value)
      return @lookup_curve.value(temp_value)
    end
    # End of class HWWaterTemp
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
      @content.shift if @content.size > @size
      @dirty = true
      return value
    end

    def value
      if @dirty
        return nil if @content.empty?

        # Filter out min-max values to further minimize jitter
        # in case of big enough filters
        if @content.size > 7
          content_tmp = Array.new(@content.sort)
          content_tmp.pop if content_tmp[content_tmp.size-1] != content_tmp[content_tmp.size-2]
          content_tmp.shift if content_tmp[0] != content_tmp[1]
        else
          content_tmp = @content
        end

        sum = 0
        content_tmp.each do
          |element|
          sum += element
        end
        @value = sum.to_f / content_tmp.size
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
      if @sensor.temp >= @threshold
        @state = :off
      else
        @state = :on
      end
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

    attr_accessor :up_histeresis, :down_histeresis
    def initialize(sensor,down_histeresis,up_histeresis,threshold,filtersize)
      @sensor = sensor
      @up_histeresis = up_histeresis
      @down_histeresis = down_histeresis
      @threshold = threshold
      @sample_filter = Filter.new(filtersize)
      if @sensor.temp >= @threshold
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
  # passed to it as an argument. The reference function should return true at times, when the PWM thermostat
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

      start_pwm_thread if defined?(@@pwm_thread) == nil
    end

    def start_pwm_thread
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
            # are to be on as in this case time is spent on HW or valve movement rather
            # than heating. This actually is only good for the active thermostats as others
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
    #End of class PwmThermostat
  end

  class Mixer_control

    FILTER_SAMPLE_SIZE = 3
    SAMPLING_DELAY = 2.1
    ERROR_THRESHOLD = 1.1
    MIXER_CONTROL_LOOP_DELAY = 6
    MOTOR_TIME_PARAMETER = 1
    UNIDIRECTIONAL_MOVEMENT_TIME_LIMIT = 60
    MOVEMENT_TIME_HYSTERESIS = 5
    def initialize(mix_sensor,cw_switch,ccw_switch,initial_target_temp=34.0)

      # Initialize class variables
      @mix_sensor = mix_sensor
      @target_temp = initial_target_temp
      @cw_switch = cw_switch
      @ccw_switch = ccw_switch

      # Create Filters
      @mix_filter = Filter.new(FILTER_SAMPLE_SIZE)

      @target_mutex = Mutex.new
      @control_mutex = Mutex.new
      @measurement_mutex = Mutex.new
      @measurement_thread_mutex = Mutex.new
      @stop_measurement_requested = Mutex.new
      @control_thread_mutex = Mutex.new
      @stop_control_requested = Mutex.new

      @control_thread = nil
      @measurement_thread = nil

      @integrated_cw_movement_time = 0
      @integrated_ccw_movement_time = 0

      # Reset the device
      reset
    end

    def set_target_temp(new_target_temp)
      @target_mutex.synchronize {@target_temp = new_target_temp}
    end

    # Move it to the middle
    def reset
      Thread.new do
        if @control_mutex.try_lock
          sleep 2
          ccw_switch.pulse(36)
          sleep 2
          cw_switch.pulse(15)
          sleep 2
          @control_mutex.unlock
        end
      end
    end

    def start_control(delay=0)
      # Only start control thread if not yet started
      return unless @control_thread_mutex.try_lock

      # Clear control thread stop sugnaling mutex
      @stop_control_requested.unlock if @stop_control_requested.locked?
      # Start control thread
      @control_thread = Thread.new do
        # Acquire lock for controlling switches
        @control_mutex.synchronize do
          # Delay starting the controller process if requested
          sleep delay

          # Prefill sample buffer to get rid of false values
          FILTER_SAMPLE_SIZE.times {@mix_filter.input_sample(@mix_sensor.temp)}

          # Do the actual control, which will return ending the thread if done
          do_control_thread

          # Clear the control thread
          @control_thread = nil
        end
      end
    end

    def stop_control
      # Return if we do not have a control thread
      return if !@control_thread_mutex.locked? or @control_thread == nil

      # Signal the control thread to exit
      @stop_control_requested.lock
      # Wait for the control thread to exit
      @control_thread.join

      # Allow the next call to start control to create a new control thread
      @control_thread_mutex.unlock
    end

    def start_measurement_thread
      return unless @measurement_thread_mutex.try_lock

      # Unlock the measurement thread exis signal
      @stop_measurement_requested.unlock if @stop_measurement_requested.locked?

      #Create a temperature measurement thread
      @measurement_thread = Thread.new do
        while !@stop_measurement_requested.locked? do
          @measurement_mutex.synchronize {@mix_filter.input_sample(@mix_sensor.temp)}
          sleep SAMPLING_DELAY unless @stop_measurement_requested.locked?
        end
        $app_logger.debug("Mixer controller measurement thread exiting")
      end
    end

    def stop_measurement_thread
      # Return if we do not have a measurement thread
      return if !@measurement_thread_mutex.locked? or @measurement_thread == nil

      # Signal the measurement thread to exit
      @stop_measurement_requested.lock

      # Wait for the measurement thread to exit
      $app_logger.debug("Mixer controller waiting for measurement thread to exit")
      @measurement_thread.join

      # Allow a next call to start_measurement thread to create
      # a new measurement thread
      @measurement_thread_mutex.unlock
    end

    # The actual control thread
    def do_control_thread

      start_measurement_thread

      # Control until if stop is requested
      while !@stop_control_requested.locked? do

        # Minimum delay between motor actuations
        sleep MIXER_CONTROL_LOOP_DELAY

        # Read target temp thread safely
        @target_mutex.synchronize {target = @target_temp}
        @measurement_mutex.synchronize {error = target - @mix_filter}

        # Adjust mixing motor if error is out of bounds
        if error.abs > ERROR_THRESHOLD

          adjustment_time = calculate_adjustment_time(error.abs)

          # Move CCW
          if error > 0 and @integrated_CCW_movement_time < UNIDIRECTIONAL_MOVEMENT_TIME_LIMIT
            ccw_switch.pulse(adjustment_time)

            # Keep track of movement time for limiting movement
            @integrated_CCW_movement_time += adjustment_time

            # Adjust available movement time for the other direction
            @integrated_CW_movement_time = MOVEMENT_TIME_LIMIT - @integrated_CCW_movement_time - MOVEMENT_TIME_HYSTERESIS
            @integrated_CW_movement_time = 0 if @integrated_CW_movement_time < 0

            # Move CW
          elsif @integrated_CW_movement_time < UNIDIRECTIONAL_MOVEMENT_TIME_LIMIT
            cw_switch.pulse(adjustment_time)

            # Keep track of movement time for limiting movement
            @integrated_CW_movement_time += adjustment_time

            # Adjust available movement time for the other direction
            @integrated_CCW_movement_time = MOVEMENT_TIME_LIMIT - @integrated_CW_movement_time - MOVEMENT_TIME_HYSTERESIS
            @integrated_CCW_movement_time = 0 if @integrated_CCW_movement_time < 0
          end

        end

        # Stop the measurement thread before exiting
        stop_measurement_thread
      end

      @integrated_cw_movement_time = 0
      @integrated_ccw_movement_time = 0

    end

    # Calculate mixer motor actuation time based on error
    # This implements a simple P type controller with limited boundaries
    def calculate_adjustment_time(error)
      retval = MOTOR_TIME_PARAMETER * error
      return 1 if retval < 1
      return 10 if retval > 10
      return retval
    end

    #End of class MixerControl
  end

  class BufferHeat
    # Constants of the class
    VALVE_MOVEMENT_TIME = 6
    MAX_HEATING_HISTORY_AGE = 180
    MINIMUM_HEATING_HISTORY_STABILITY_AGE = 15
    BUFFER_HEAT_CONTROL_LOOP_DELAY = 1
    DELTA_T_STABILITY_SLOPE_THRESHOLD = 2
    BUFFER_BASE_TEMP = 20.0

    # Heat initialization constants
    INIT_BUFFER_REQD_TEMP_RESERVE = 3.0
    INIT_BUFFER_REQUD_FILL_RESERVE = 50

    #Heating delta_t maintenance related constants
    MINIMUM_DELTA_T_TO_MAINTAIN = 3.0
    BUFFER_PASSTHROUGH_OVERSHOOT = 3.0
    BUFFER_EXPIRY_THRESHOLD = 3.0
    BUFFER_PASSTHROUGH_FWD_TEMP_LIMIT = 40.0
    TRANSITION_DELAY = 10
    # Initialize the buffer taking its sensors and control valves
    def initialize(forward_sensor, upper_sensor, lower_sensor, return_sensor,
      hw_thermostat,
      forward_valve, return_valve,
      heater_relay, hydr_shift_pump, hw_pump,
      hw_wiper, heat_wiper,
      config)
      # Buffer Sensors
      @forward_sensor = forward_sensor
      @upper_sensor =  upper_sensor
      @lower_sensor = lower_sensor
      @return_sensor = return_sensor

      # HW_thermostat for filtered value
      @hw_thermostat = hw_thermostat

      # Valves
      @forward_valve = forward_valve
      @return_valve = return_valve

      # Pump, heat relay
      @heater_relay = heater_relay
      @hydr_shift_pump = hydr_shift_pump
      @hw_pump = hw_pump

      # Temp wipers
      @hw_wiper = hw_wiper
      @heat_wiper = heat_wiper

      # Remember the heating config map by reference
      @config = config

      # The control thread
      @control_thread = nil

      # This one ensures that there is only one control thread running
      @control_mutex = Mutex.new

      # This one signals the control thread to exit
      @stop_control = Mutex.new

      # Initialize the heating history
      @heating_history = []
      @delta_analyzer = Globals::TempAnalyzer.new(6)
      @initialize_heating = true
      @buffer_exit_limit = 0

      # Set the initial state
      @mode = :off
      @control_thread = nil
      @relay_state = nil
      set_relays(:direct_boiler)
      @heating_feed_state = :initializing
      @heat_in_buffer = {:temp=>@upper_sensor.temp,:percentage=>((@lower_sensor.temp - BUFFER_BASE_TEMP)*100)/(@upper_sensor.temp - BUFFER_BASE_TEMP)}
      @target_temp = 7.0
    end

    # Set the operation mode of the buffer. This can take the below values as a parameter:
    #
    # :heat - The system is configured for heating. Heat is provided by the boiler or by the buffer.
    #         The logic actively decides what to do and how the valves/heating relays
    #         need to be configured
    #
    # :off - The system is configured for being turned off. The remaining heat from the boiler - if any - is transferred to the buffer.
    #
    # :HW - The system is configured for HW - Boiler relays are switched off  - this now does not take the solar option into account.

    def set_mode(new_mode)
      # Check validity of the parameter
      raise "Invalid mode parameter '"+new_mode.to_s+"' passed to set_mode(mode)" unless [:heat,:off,:HW].include? new_mode

      # Take action only if the mode is changing
      return if @mode == new_mode

      # Maintain the mode history and set the mode change flag
      @prev_mode = @mode
      @mode = new_mode
      @mode_changed = true

      case new_mode
      when :heat
        $app_logger.debug("Heater set_mode. Got new mode: :heat")
        start_control_thread
      when :off
        $app_logger.debug("Heater set_mode. Got new mode: :off")
        stop_control_thread
      when :HW
        $app_logger.debug("Heater set_mode. Got new mode: :HW")
        set_relays(:direct_boiler)
        start_control_thread
      end

    end

    # Set the required forward water temperature
    def set_target(new_target_temp)
      #      @target_changed = (new_target_temp == @target_temp)
      @target_temp = new_target_temp
    end

    # Configure the relays for a certain purpose
    def set_relays(config)
      # Check validity of the parameter
      raise "Invalid relay config parameter '"+config.to_s+"' passed to set_relays(config)" unless
      [:direct_boiler,:buffer_passthrough,:feed_from_buffer].include? config

      $app_logger.debug("Relay state is: "+@relay_state.to_s)

      return if @relay_state == config

      moved = false

      case config
      when :direct_boiler
        $app_logger.debug("Setting relays to ':direct_bolier'")
        moved |= @forward_valve.state != :off
        @forward_valve.off
        moved |= @return_valve.state != :off
        @return_valve.off
        @relay_state = :direct_boiler
      when :buffer_passthrough
        $app_logger.debug("Setting relays to ':buffer_passthrough'")
        moved |= @forward_valve.state != :off
        @forward_valve.off
        moved |= @return_valve.state != :on
        @return_valve.on
        @relay_state = :buffer_passthrough
      when :feed_from_buffer
        $app_logger.debug("Setting relays to ':feed_from_buffer'")
        moved |= @forward_valve.state != :on
        @forward_valve.on
        moved |= @return_valve.state != :off
        @return_valve.off
        @relay_state = :feed_from_buffer
      end

      if moved
        $app_logger.debug("Waiting for relays to move into new state")
      else
        $app_logger.debug("Relays not moved - skippling sleep")
      end

      # Wait until valve movement is complete
      sleep VALVE_MOVEMENT_TIME unless !moved

      if moved
        return :delayed
      else
        return :immediate
      end
    end

    private

    # Maintain the heating history
    def maintain_heating_metadata(calling_mode)
      # Maintain the heating history
      if calling_mode == :initialize
        $app_logger.debug("Maintaining heatnig metadata - initializing metadata storage: "+calling_mode.to_s)
        @heating_history.clear
        @delta_analyzer.reset
      else
        $app_logger.debug("Maintaining heatnig metadata - appending to metadata storage: "+calling_mode.to_s)
      end

      current_heating_history_entry = {:forward_temp=>@forward_sensor.temp,:return_temp=>@return_sensor.temp,
        :upper_temp=>@upper_sensor.temp,:lower_temp=>@lower_sensor.temp,:delta_t=>0,
        :timestamp=>Time.now.getlocal(0)}

      current_heating_history_entry[:delta_t] = current_heating_history_entry[:forward_temp] - current_heating_history_entry[:return_temp]

      @heating_history.push(current_heating_history_entry)

      @heating_history.shift if Time.now.getlocal(0) - @heating_history.first[:timestamp] > MAX_HEATING_HISTORY_AGE

      # Maintain the amount of heat stored in the buffer
      @heat_in_buffer = {:temp=>@upper_sensor.temp,:percentage=>((@lower_sensor.temp - BUFFER_BASE_TEMP)*100.0)/(@upper_sensor.temp - BUFFER_BASE_TEMP)}

      # Update the heating delta analyzer
      @delta_analyzer.update(current_heating_history_entry[:delta_t])
    end # of maintain_heating_metadata

    #
    # Evaluate heating conditions and
    # set feed strategy
    # This routine only sets relays and heat switches no pumps
    # circulation is expected to be stable when called
    #
    def set_heating_feed(calling_mode)

      maintain_heating_metadata(calling_mode)

      current_delta_t = @heating_history.last[:delta_t]
      current_forward_temp = @heating_history.last[:forward_temp]

      # Determine the heating feed state
      @prev_heating_feed_state = @heating_feed_state

      if calling_mode == :initialize
        @heating_feed_state = :initializing
      elsif @delta_analyzer.slope.abs > DELTA_T_STABILITY_SLOPE_THRESHOLD or
      Time.now.getlocal(0) - @heating_history.first[:timestamp]  < MINIMUM_HEATING_HISTORY_STABILITY_AGE
        @heating_feed_state = :unstable
      else
        @heating_feed_state = :stable
      end

      $app_logger.debug("Determined heating feed state: "+@heating_feed_state.to_s)
      $app_logger.debug("Prev heating feed state was: "+@prev_heating_feed_state.to_s)

      # If the measurement has not yet started perform initialization
      if @heating_feed_state == :initializing
        $app_logger.debug("Heat in buffer: "+@heat_in_buffer[:temp].to_s+" Percentage: "+@heat_in_buffer[:percentage].to_s)
        $app_logger.debug("Target temp: "+@target_temp.to_s)

        if @heat_in_buffer[:temp] > @target_temp + INIT_BUFFER_REQD_TEMP_RESERVE and @heat_in_buffer[:percentage] > INIT_BUFFER_REQUD_FILL_RESERVE
          @heater_relay.off
          @heat_wiper.set_water_temp(7.0)
          set_relays(:feed_from_buffer)
        else
          set_relays(:direct_boiler)
          @heater_relay.on
          @heat_wiper.set_water_temp(@target_temp)
        end

        # Monitor Delta_t and make feed decison based on it
      elsif @heating_feed_state == :stable
        $app_logger.debug("Relay state: "+@relay_state.to_s)

        # Evaluate Direct Boiler state
        if @relay_state == :direct_boiler
          $app_logger.debug("current_delta_t: "+current_delta_t.to_s)

          # Direct Boiler - State change condition evaluation
          if current_delta_t < MINIMUM_DELTA_T_TO_MAINTAIN
            # Too much heat with direct heat - let's either feed from buffer or fill the buffer
            # based on how much heat is stored in the buffer
            $app_logger.debug("State will change")
            $app_logger.debug("Heat in buffer: "+@heat_in_buffer[:temp].to_s+" Percentage: "+@heat_in_buffer[:percentage].to_s)
            $app_logger.debug("Target temp: "+@target_temp.to_s)

            if @heat_in_buffer[:temp] > @target_temp + INIT_BUFFER_REQD_TEMP_RESERVE and @heat_in_buffer[:percentage] > INIT_BUFFER_REQUD_FILL_RESERVE
              @heater_relay.off
              @heat_wiper.set_water_temp(7.0)
              set_relays(:feed_from_buffer)
            else
              $app_logger.debug("State will change")
              set_relays(:buffer_passthrough)

              # Remember the target temp that the system was unable to dissipate
              # in direct feed mode. This is then used as a lower limiter for exiting from
              # buffer passthrough mode - this is a learning type mechanism for allowing the boiler temp
              # to be raised up until temperatures that have already been seen as temperatures that
              # the system is unable to dissipate. A hysteresis logic is used using the same hysteresis as is used for
              # the extra amount of heat requred from the boiled in case of buffer passthrough heating
              @buffer_exit_limit = @target_temp + BUFFER_PASSTHROUGH_OVERSHOOT
              # If feed heat into buffer raise the boiler temperature to be able to move heat out of the buffer later
              @heat_wiper.set_water_temp(@target_temp + BUFFER_PASSTHROUGH_OVERSHOOT)
            end

            # Direct Boiler - State maintenance operations
            # Just set the required water temperature
          else
            $app_logger.debug("State does not change - setting target: "+@target_temp.to_s)
            @heat_wiper.set_water_temp(@target_temp)
          end

          # Evaluate Buffer Passthrough state
        elsif @relay_state == :buffer_passthrough
          $app_logger.debug("Target temp: "+@target_temp.to_s+" Buffer exit limit: "+@buffer_exit_limit.to_s)
          $app_logger.debug("Current_delta_t: "+current_delta_t.to_s)
          # Buffer Passthrough - State change evaluation conditions

          # Move out of buffer feed if the required temperature rose above the exit limit
          # This logic is here to try forcing the heating back to direct heating in cases where
          # the heat generated can be dissipated. This is more of a safety escrow
          # to try avoiding unnecessary buffer filling
          if @target_temp > @buffer_exit_limit
            $app_logger.debug("State will change")

            set_relays(:direct_boiler)
            @heat_wiper.set_water_temp(@target_temp)

            # If the buffer is nearly full - too low delta T or
            # too hot then start feeding from the buffer.
            # As of now we assume that the boiler is able to generate the output temp requred
            # therefore it is enough to monitor the deltaT to find out if the above condition is met
          elsif current_delta_t < MINIMUM_DELTA_T_TO_MAINTAIN
            $app_logger.debug("State will change")

            @heater_relay.off
            @heat_wiper.set_water_temp(7.0)
            set_relays(:feed_from_buffer)

            # Buffer Passthrough - State maintenance operations
            # Just set the required water temperature
            # raised with the buffer filling offset
          else
            $app_logger.debug("State will not change setting target temp to: "+(@target_temp + BUFFER_PASSTHROUGH_OVERSHOOT).to_s)
            @heat_wiper.set_water_temp(@target_temp + BUFFER_PASSTHROUGH_OVERSHOOT)
          end

          # Evaluate feed from Buffer state
        elsif @relay_state == :feed_from_buffer
          $app_logger.debug("Current_forward_temp: "+current_forward_temp.to_s)
          $app_logger.debug("Target temp: "+@target_temp.to_s+" Buffer exit limit: "+@buffer_exit_limit.to_s)

          # Feeed from Buffer - - State change evaluation conditions

          # If the buffer is empty: unable to provide at least the target temp minus the hysteresis
          # then it needs re-filling. This will ensure an operation of filling the buffer with
          # target+BUFFER_PASSTHROUGH_OVERSHOOT and consuming until target-BUFFER_EXPIRY_THRESHOLD
          # The effective hysteresis is therefore BUFFER_PASSTHROUGH_OVERSHOOT+BUFFER_EXPIRY_THRESHOLD
          if current_forward_temp < @target_temp - BUFFER_EXPIRY_THRESHOLD

            # If we are below the exit limit then go for filling the buffer
            # This starts off from zero (0), so for the first time it will need a limit set in
            # direct_boiler operation mode
            if @target_temp < @buffer_exit_limit
              $app_logger.debug("State will change")

              set_relays(:buffer_passthrough)
              @heater_relay.on
              @heat_wiper.set_water_temp(@target_temp + BUFFER_PASSTHROUGH_OVERSHOOT)

              # If the target is above the exit limit then go for the direct feed
              # which in turn may set a viable exit limit
            else
              $app_logger.debug("State will change")

              set_relays(:direct_boiler)
              @heater_relay.on
              @heat_wiper.set_water_temp(@target_temp)
            end
          end
          $app_logger.debug("State will not change - continue feeding from buffer while doing nothing")
          # Raise an exception - no matching source state
        else
          raise "Unexpected relay state in set_heating_feed: "+@relay_state.to_s
        end

      elsif @heating_feed_state == :unstable
        $app_logger.info("Heating unstable. DeltaT slope: "+@delta_analyzer.slope.to_s+"; History age: "+(Time.now.getlocal(0) - @heating_history.first[:timestamp]).to_s)
      else
        raise "Unexpected heating_feed_state: "+@heating_feed_state.to_s
      end
    end # of set_heating_feed

    # The actual tasks of the control thread
    def do_control

      if @mode_changed
        $app_logger.debug("Heater control mode changed, got new mode: "+@mode.to_s)
        case @mode
        when :HW
          @hw_pump.on
          sleep @config[:circulation_maintenance_delay] if ( set_relays(:direct_boiler) != :delayed)
          @hydr_shift_pump.off
          @hw_wiper.set_water_temp(@hw_thermostat.temp)
        when :heat
          # Make sure HW mode of the boiler is off
          @hw_wiper.set_water_temp(65.0)
          @hydr_shift_pump.on
          sleep @config[:circulation_maintenance_delay]
          set_heating_feed(:initialize)
        else
          raise "Invalid mode in do_control after mode change. Expecting either ':HW' or ':heat' got: '"+@mode.to_s+"'"
        end
        @mode_changed = false
      else
        $app_logger.debug("Heater control mode not changed, mode is: "+@mode.to_s)
        case @mode
        when :HW
          @hw_wiper.set_water_temp(@hw_thermostat.temp)
        when :heat
          set_heating_feed(:continuous)
        else
          raise "Invalid mode in do_control. Expecting either ':HW' or ':heat' got: '"+@mode.to_s+"'"
        end
      end
    end

    # Control thread controlling functions
    # Start the control thread
    def start_control_thread
      # This section is synchronized to the control mutex.
      # Only a single control thread may exist
      return unless @control_mutex.try_lock

      # Set the stop thread signal inactive
      @stop_control.unlock if @stop_control.locked?

      # The controller thread
      @control_thread = Thread.new do
        $app_logger.debug("Heater control thread created")

        # Loop until signalled to exit
        while !@stop_control.locked?
          do_control
          sleep BUFFER_HEAT_CONTROL_LOOP_DELAY unless @stop_control.locked?
        end
        # Stop heat production of the boiler
        @heater_relay.off

        $app_logger.debug("Heater control thread exiting")
      end # Of control Thread

    end # Of start_control_thread

    # Signal the control thread to stop
    def stop_control_thread
      # Only stop the control therad if it is alive
      return if !@control_mutex.locked? or @control_thread == nil

      # Signal control thread to exit
      @stop_control.lock
      # Wait for the thread to exit
      @control_thread.join

      # Unlock the thread lock so a new call to start_control_thread
      # can create the control thread
      @control_mutex.unlock
    end
  end
end