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
  end

  def forward_temp
    @forward_temp_sensor.value
  end

  def pump_rpm
    @waterpump_rpm_sensor.value
  end

  def compressor_rpm
    @compressor_rpm_sensor.value
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
                                                { hp_device: @hp_device, name: 'HP Forward temp sensor',
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
  end
end
