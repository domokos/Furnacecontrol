#!/usr/bin/ruby
# frozen_string_literal: true

require 'rmodbus'

modbus = ModBus::RTUClient.new('/dev/ttyUSB1', 19_200, { data_bits: 8, parity: 0, stop_bits: 2 })
SLAVE_ADDRESS = 1

modbus.with_slave(SLAVE_ADDRESS) do |slave|
  # Read a single holding register at address 16
  puts 'DHW temp: '
  puts slave.input_registers[16]

  puts 'Outgoing temp mode'
  puts slave.holding_registers[1]

  puts 'Outgoing set point'
  # Outgoing Zone1 setpoint
  slave.holding_registers[2] = 370
  puts slave.holding_registers[2]

  puts 'Max outgoing set point'
  # Max Outgoing Zone1 setpoint
  puts slave.holding_registers[3]
end
