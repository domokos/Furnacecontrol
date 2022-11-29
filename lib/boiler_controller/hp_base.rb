# frozen_string_literal: true

module HPBase
  # Direct Discrete inputs logger
  class ModbusDiscreteInputsLogger
    def initialize(busmutex, hp_device, logger)
      @busmutex = busmutex
      @hp_device = hp_device
      @logger = logger
      @inputs = []
    end

    def log_all_discrete_inputs
      @busmutex.synchronize { @inputs.push(@hp_device.discrete_inputs[0..34]) }
      @inputs.shift if @inputs.size > 15
      @logger.debug('Logging disrete inputs:')
      0.upto(@inputs.size - 1) { |i| @logger.debug("item: #{@inputs[i].join(',')}") }
    end
  end

  # The class of the HP value sensor
  class HPSensor
    attr_reader :name, :slave_address
    attr_accessor :mock_value

    DEFAULT_VALUE = 0

    def initialize(busmutex, param)
      @busmutex = busmutex
      @hp_device = param[:hp_device]
      @logger = param[:config].logger.app_logger
      @config = param[:config]
      @name = param[:name]
      @register_address = param[:register_address]
      @register_type = param[:register_type]
      @multiplier = param[:multiplier].nil? ? 1 : param[:multiplier]
      @signed = param[:signed].nil? || param[:signed] ? true : false

      @value_reader_mutex = Mutex.new

      @delay_timer = Globals::TimerSec.new(@config[:hp_bus_values_read_period],
                                           "HP value Sensor Delay timer: #{@name}")

      # Perform initial valueerature read
      @delay_timer.reset
      initial_value = read_value
      @lastvalue = initial_value.nil? ? DEFAULT_VALUE : initial_value
    end

    def value
      @value_reader_mutex.synchronize do
        if @delay_timer.expired?
          value_tmp = read_value
          @lastvalue = value_tmp
          @delay_timer.reset
        end
      end
      @lastvalue
    end

    private

    def to_signed16(num)
      # length = 16 # in bits
      mid = 32_768 # 2**(length - 1)
      max_unsigned = 65_536 # 2**length
      num >= mid ? num - max_unsigned : num
    end

    def read_value
      val = 0
      case @register_type
      when :input
        @busmutex.synchronize { val = @hp_device.input_registers[@register_address].first }
        @signed ? to_signed16(val) * @multiplier : val * @multiplier
      when :holding
        @busmutex.synchronize { val = @hp_device.holding_registers[@register_address].first }
        @signed ? to_signed16(val) * @multiplier : val * @multiplier
      end
    rescue StandardError => e
      # Log the messaging error
      @logger.fatal('Unrecoverable communication error on HP modbus '\
        "reading #{@name}")
      @logger.fatal("Exception caught in main block: #{e.inspect}")
      @logger.fatal("Exception backtrace: #{e.backtrace.join("\n")}")
      # Signal the main thread for fatal error shutdown
      @config.shutdown_reason = Globals::FATAL_SHUTDOWN
      @lastvalue
    end
    # End of Class definition HPvalueSensor
  end
  # End of module HPBase
end
