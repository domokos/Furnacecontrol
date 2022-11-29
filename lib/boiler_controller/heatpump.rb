# frozen_string_literal: true

require '/usr/local/lib/boiler_controller/hp_base'
require 'rmodbus'

# class of the Heat Pump
class HeatPump
  attr_reader :mode

  def initialize(config)
    @logger = config.logger.app_logger
    @heating_logger = config.logger.heating_logger
    @config = config

    @modbus = \
      ModBus::RTUClient.new(@config[:hp_modbus_serial_device],\
                            @config[:hp_modbus_speed],\
                            { data_bits: @config[:hp_modbus_data_bits],\
                              parity: @config[:hp_modbus_parity],\
                              stop_bits: @config[:hp_modbus_stop_bits] })
    @hp_device = @modbus.with_slave(@config[:hp_modbus_slave_addr])

    @busmutex = Mutex.new

    @mode = :heating
    @logger = config.logger.app_logger

    @heating_targettemp = 20

    create_sensors

    start_discrete_inputs_logger_thread
  end

  def forward_temp
    @forward_temp_sensor.value
  end

  def return_temp
    @return_sensor.value
  end

  def discahrge_temp
    @discahrge_sensor.value
  end

  def defrost_temp
    @defrost_sensor.value
  end

  def suction_temp
    @suction_sensor.value
  end

  def exchanger_temp
    @exchanger_sensor.value
  end

  def pump_rpm
    @waterpump_rpm_sensor.value
  end

  def compressor_rpm
    @compressor_rpm_sensor.value
  end

  def fan_rpm
    @fan_rpm_sensor.value
  end

  def power
    @power_sensor.value
  end

  def mode=(new_mode)
    @mode = new_mode
    @busmutex.synchronize { @hp_device.holding_registers[@config[:hp_operating_mode_addr]] = new_mode }
  end

  # Heating target temp
  def heating_targettemp=(new_targettemp)
    return if up_to_nearest_five((new_targettemp.round(1) * 10).round(0)) == @heating_targettemp

    @heating_targettemp = up_to_nearest_five((new_targettemp.round(1) * 10).round(0))
    @logger.debug("Setting HP target watertemp to #{@heating_targettemp/10.0}")
    @busmutex.synchronize\
     { @hp_device.holding_registers[@config[:hp_heating_zone1_setpoint_addr]] = @heating_targettemp }
  end

  def heating_targettemp
    @heating_targettemp / 10.0
  end

  private

  def up_to_nearest_five(num)
    return num if (num % 5).zero?

    rounded = num.round(-1)
    rounded > num ? rounded : rounded + 5
  end

  def create_sensors
    @forward_temp_sensor = HPBase::HPSensor.new(@busmutex,
                                                { hp_device: @hp_device, name: 'HP Forward temp',
                                                  register_address: @config[:hp_outgoing_water_temp_addr],
                                                  register_type: :input, config: @config })

    @waterpump_rpm_sensor = HPBase::HPSensor.new(@busmutex,
                                                 { hp_device: @hp_device, name: 'HP Waterpump RPM',
                                                   register_address: @config[:hp_water_pump_rpm_addr],
                                                   register_type: :input, config: @config,
                                                   multiplier: @config[:hp_water_pump_rpm_multiplier] })

    @compressor_rpm_sensor = HPBase::HPSensor.new(@busmutex,
                                                  { hp_device: @hp_device, name: 'HP Compressor RPM',
                                                    register_address: @config[:hp_compressor_rpm_addr],
                                                    register_type: :input, config: @config,
                                                    multiplier: @config[:hp_compressor_rpm_multiplier] })

    @power_sensor = HPBase::HPSensor.new(@busmutex,
                                         { hp_device: @hp_device, name: 'HP Current Power Consumed',
                                           register_address: @config[:hp_current_consumption_addr],
                                           register_type: :input, config: @config,
                                           multiplier: @config[:hp_current_consumption_multiplier] })

    @fan_rpm_sensor = HPBase::HPSensor.new(@busmutex,
                                           { hp_device: @hp_device, name: 'HP Fan RPM',
                                             register_address: @config[:hp_fan_rpm_addr],
                                             register_type: :input, config: @config,
                                             multiplier: @config[:hp_fan_rpm_multiplier] })

    @return_sensor = HPBase::HPSensor.new(@busmutex,
                                          { hp_device: @hp_device, name: 'HP Return temp',
                                            register_address: @config[:hp_return_water_temp_addr],
                                            register_type: :input, config: @config })

    @discahrge_sensor = HPBase::HPSensor.new(@busmutex,
                                             { hp_device: @hp_device, name: 'HP Discharge temp',
                                               register_address: @config[:hp_discharge_temperature_addr],
                                               register_type: :input, config: @config })

    @defrost_sensor = HPBase::HPSensor.new(@busmutex,
                                           { hp_device: @hp_device, name: 'HP Defrost temp',
                                             register_address: @config[:hp_defrost_temp_addr],
                                             register_type: :input, config: @config })

    @suction_sensor = HPBase::HPSensor.new(@busmutex,
                                           { hp_device: @hp_device, name: 'HP Suction temp',
                                             register_address: @config[:hp_suction_temp_addr],
                                             register_type: :input, config: @config })

    @exchanger_sensor = HPBase::HPSensor.new(@busmutex,
                                             { hp_device: @hp_device, name: 'HP Heat Exchanger temp',
                                               register_address: @config[:hp_heat_exchanger_temp_addr],
                                               register_type: :input, config: @config })
  end

  def start_discrete_inputs_logger_thread
    Thread.new do
      direct_modbus = HPBase::ModbusDiscreteInputsLogger.new(@busmutex, @hp_device, @logger)
      @logger_timer = Globals::TimerSec.new(5, 'HP Discrete input logger timer')
      @logger_timer.reset
      while @config.shutdown_reason == Globals::NO_SHUTDOWN
        if @logger_timer.expired?
          @logger_timer.reset
          direct_modbus.log_all_discrete_inputs
        end
        sleep 1
      end
    end
  end
end
