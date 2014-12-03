#!/usr/local/rvm/rubies/ruby-2.1.5/bin/ruby

require "./Buscomm"
require "rubygems"

STDOUT.sync = true

#Parameters
SERIALPORT_NUM = 0
COMM_SPEED = Buscomm::COMM_SPEED_9600_H
MASTER_ADDRESS = 1

my_comm = Buscomm.new(1,SERIALPORT_NUM,COMM_SPEED)

#mode = "do HW"
mode = "do heat"
#mode = "off"
#mode = "test"

print "Mode: " + mode + "\n"

if mode == "do heat"
# Turn on Basement floor valve
    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,9.chr+0.chr)
# Turn on Basement radiator valve
    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,10.chr+1.chr)
# Turn on Rad pump
    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,5.chr+1.chr)
# Hidr shift pump 
   ret = my_comm.send_message(11,Buscomm::SET_REGISTER,7.chr+1.chr)
# Floor pump
    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,6.chr+1.chr)
# HW pump
    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,8.chr+0.chr)
# Turn on heater relay
    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,11.chr+1.chr)
# Set water temp
    wiper_val = 0x96
    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,12.chr+0x0.chr+wiper_val.chr+0.chr)

# 0xff - 85
# 0xfb - 85
# 0xf8 - 84
# 0xf4 - 80
# 0xf0 - 74
# 0xeb - 69
# 0xe8 - 65
# 0xe0 - 58
# 0xd8 - 54
# 0xd0 - 49
# 0xc0 - 42
# 0xa9 - 44
# 0x99 - 39
# 0x96 - 34
# 0x10 - <27 C
# 0x60 - >26 C - turns on from 26 30?

elsif mode == "do HW"
# Turn off Rad pump
    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,5.chr+0.chr)
# Hidr shift pump
    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,7.chr+0.chr)
# Floor pump
    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,6.chr+0.chr)
# HW pump
    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,8.chr+1.chr)
# RAd pump
    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,5.chr+0.chr)
# Turn on heater relay
    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,11.chr+1.chr)
# Set water temp

    wiper_val = 0xff
    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,12.chr+0x0.chr+wiper_val.chr+0.chr)

elsif mode == "off"
# Turn on Basement radiator valve
    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,10.chr+1.chr)
# Turn on Rad pump
    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,5.chr+1.chr)
# Hidr shift pump 
   ret = my_comm.send_message(11,Buscomm::SET_REGISTER,7.chr+1.chr)
# Floor pump
    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,6.chr+1.chr)

# Turn of heater relay
    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,11.chr+0.chr)
    sleep 80
# Turn off Basement floor valve
    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,9.chr+0.chr)
# Turn off Basement radiator valve
    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,10.chr+0.chr)
# Turn off Rad pump
    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,5.chr+0.chr)
# Hidr shift pump 
   ret = my_comm.send_message(11,Buscomm::SET_REGISTER,7.chr+0.chr)
# Floor pump
    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,6.chr+0.chr)
# HW pump
    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,8.chr+0.chr)

elsif mode == "test"

#    wiper_val = 0xff
#    ret = my_comm.send_message(11,Buscomm::SET_REGISTER,12.chr+0x0.chr+wiper_val.chr+0.chr)

#    ret = my_comm.send_message(11,Buscomm::READ_REGISTER,12.chr+0.chr)
    ret = my_comm.send_message(11,Buscomm::READ_REGISTER,4.chr)

    my_comm.printret(ret)

end
