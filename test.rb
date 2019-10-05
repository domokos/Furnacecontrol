#!/usr/local/rvm/rubies/ruby-2.3.0/bin/ruby

require '/usr/local/lib/boiler_controller/buscomm'
require '/usr/local/lib/boiler_controller/boiler_base'
require 'rubygems'
require 'yaml'

STDOUT.sync = true

# Config file paths
CONFIG_FILE_PATH = '/etc/boiler_controller/boiler_controller.yml'
TEST_CONTROL_FILE_PATH = '/etc/boiler_controller/boiler_test_controls.yml'

config = Globals::Config.new(logger, CONFIG_FILE_PATH)

#Parameters
SERIALPORT_NUM = '/dev/ttyUSB0'
COMM_SPEED = Buscomm::COMM_SPEED_9600_H
MASTER_ADDRESS = 1

my_comm = Buscomm.new(config, COMM_SPEED)

config = YAML.load_file("/etc/boiler_controller/boiler_controller.yml")

#mode = "do HW"
#mode = "do heat"
#mode = "off"
mode = 'test'

print "Mode: " + mode + "\n"

if mode == "do heat"
# Set water temp 
    wiper_val = 0x99
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:heating_wiper_reg_addr].chr+0x0.chr+wiper_val.chr+1.chr)

#    sleep 60

# Basement floor valve
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:basement_floor_valve_reg_addr].chr+0.chr)
# Basement radiator valve
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
                               config[:basement_radiator_valve_reg_addr].chr+0.chr)
# Rad pump
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:radiator_pump_reg_addr].chr+0.chr)
# Hidr shift pump 
   ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:hydr_shift_pump_reg_addr].chr+1.chr)

# HW Valve 
   ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:hw_valve_reg_addr].chr+0.chr)

# Turn on Basement floor valve
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:basement_floor_valve_reg_addr].chr+1.chr)

# Floor pump
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:floor_pump_reg_addr].chr+1.chr)
# HW pump
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:hot_water_pump_reg_addr].chr+0.chr)
# Heater relay
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:heater_relay_reg_addr].chr+1.chr)

# 0xff - 85
# 0xfb - 85
# 0xf8 - 84
# 0xf4 - 80
# 0xf0 - 74
# 0xeb - 69 --- 73.5
# 0xe8 - 65 --- 71
# 0xe0 - 58 --- 63.5
# 0xd8 - 54 --- 57.25
# 0xd0 - 49 --- 53.25
# 0xc8 -    --- 49.125
# 0xc0 - 42 --- 46.5
# 0xa9 - 44 --- 41
# 0x99 - 39
# 0x96 - 34
# 0x10 - <27 C
# 0x60 - >26 C - turns on from 26 30?

while true
    ret = my_comm.send_message(config[:mixer_controller_dev_addr],Buscomm::READ_REGISTER,
       config[:forward_sensor_reg_addr].chr)
    puts "Fwd sensor"

    my_comm.printret(ret)
    sleep 2
end


elsif mode == "do HW"
# HW pump
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:hot_water_pump_reg_addr].chr+1.chr)
sleep 0.5
# Turn off Rad pump
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:radiator_pump_reg_addr].chr+0.chr)
# Turn off Floor pump
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:floor_pump_reg_addr].chr+0.chr)
# Turn off Hidr shift pump
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:hydr_shift_pump_reg_addr].chr+0.chr)

# Turn on forward valve
ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
                               config[:forward_valve_reg_addr].chr+1.chr)
# Turn on HW pump
	ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:hot_water_pump_reg_addr].chr+1.chr)

# Turn off heater relay
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:heater_relay_reg_addr].chr+0.chr)
# Set hw water temp

    wiper_val = 0x01
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:hw_wiper_reg_addr].chr+0x0.chr+wiper_val.chr+1.chr)

sleep 10000

elsif mode == "off"
# Set hw water temp - HW off
    wiper_val = 0xfa
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:hw_wiper_reg_addr].chr+0x0.chr+wiper_val.chr+1.chr)

# Turn on Basement radiator valve
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
                               config[:basement_radiator_valve_reg_addr].chr+1.chr)
# Turn on Rad pump
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:radiator_pump_reg_addr].chr+1.chr)
# Turn on Hidr shift pump 
   ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:hydr_shift_pump_reg_addr].chr+1.chr)
# Floor pump
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:floor_pump_reg_addr].chr+1.chr)

# Turn off heater relay
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:heater_relay_reg_addr].chr+0.chr)
    sleep 10
# Turn off Basement floor valve
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:basement_floor_valve_reg_addr].chr+0.chr)
# Turn off Basement radiator valve
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
                               config[:basement_radiator_valve_reg_addr].chr+0.chr)
# Turn off Rad pump
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:radiator_pump_reg_addr].chr+0.chr)
# Hidr shift pump 
   ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:hydr_shift_pump_reg_addr].chr+0.chr)
# Floor pump
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:floor_pump_reg_addr].chr+0.chr)
# HW pump
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:hot_water_pump_reg_addr].chr+0.chr)

# Set hw water temp
    wiper_val = 0xfa
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:hw_wiper_reg_addr].chr+0x0.chr+wiper_val.chr+1.chr)

elsif mode == "test"

#    ret = my_comm.send_message(config[:mixer_controller_dev_addr],Buscomm::PING,"")
#    my_comm.printret(ret)

# Set hw water temp - HW off
    wiper_val = 0xfa
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:hw_wiper_reg_addr].chr+0x0.chr+wiper_val.chr+1.chr)

# Turn on forward valve
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
                               config[:forward_valve_reg_addr].chr+1.chr)
# Turn on HW pump
    ret = my_comm.send_message(config[:main_controller_dev_addr],Buscomm::SET_REGISTER,
			       config[:hot_water_pump_reg_addr].chr+1.chr)
           
    my_comm.printret(ret)

    sleep 180
end
