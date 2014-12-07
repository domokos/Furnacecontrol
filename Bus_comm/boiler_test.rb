#!/usr/local/rvm/rubies/ruby-2.1.5/bin/ruby

require "./Buscomm"
require "./boiler_base"
require "rubygems"
require "robustthread"


switch = BusDevice::Switch.new("Test switch","At a mock location",1,1,false)

while true
end