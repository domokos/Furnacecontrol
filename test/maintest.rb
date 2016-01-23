#!/usr/local/rvm/rubies/ruby-2.1.5/bin/ruby
require '/home/boiler/git/Furnacecontrol/test/sinatratest.rb'

class Alma
  attr_accessor :value
  def initialize(value)
    @value = value
  end

  def szorzott(szorzo)
    @value * szorzo
  end

  def operate
    num = 0
    while true do
      sleep 1
      puts "Sleeping loop"
      num += 1
      puts num
    end
  end
end

myalma = Alma.new(2)

puts myalma.szorzott(2)

puts "Starting restapi"

mythread = Thread.new do

  puts "Starting restapi"
  $BoilerRestapi.run!
  puts "Restapi stoppped"
end

sleep 15

puts "Stopping restapi"

mythread.kill
