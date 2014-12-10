#!/usr/local/rvm/rubies/ruby-2.1.5/bin/ruby

require "./Buscomm"
require "./boiler_base"
require "rubygems"
require "robustthread"


switch = BusDevice::Switch.new("Test switch","At a mock location",1,1,false)

watertemp = BusDevice::WaterTemp.new("Test Water Temp regulator", "At another mock location", 2, 2, false)

temp_sensor = BusDevice::TempSensor.new("Test temp sensor", "Mock tempsensor location", 3, 3, 2, false)

valve = BusDevice::DelayedCloseMagneticValve.new("Test valve","At yet another mock location", 4, 4, false)


while true
end