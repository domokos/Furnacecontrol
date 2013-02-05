#!/usr/bin/ruby
# Furnace user interface module
# Version 1 - 11 Feb 2009
#

$stdout.sync = true
require 'rubygems'
require 'serialport'
require 'thread'

$debuglevel = 0
$do_tests = false

#Parameters
SERIALPORT_NUM=0
PARITY=0
STOPBITS=1
BAUD=4800
DATABITS=8

#Control commands
MESSAGE_TERMINATOR=0
MESSAGE_HEAD=204

#Host identifier
HOST_ID=1

#Serial command set from UI to controller
SET_TARGET_LIVING_TEMP=1
SET_TARGET_UPSTAIRS_TEMP=2
SET_TARGET_BASEMENT_TEMP=3
ACK_SET_TARGET_LIVING_TEMP=21
ACK_SET_TARGET_UPSTAIRS_TEMP=22
ACK_SET_TARGET_BASEMENT_TEMP=23

#Serial command set from controller to UI
COMMUNICATE_LIVING_TEMP=4
COMMUNICATE_UPSTAIRS_TEMP=5
COMMUNICATE_BASEMENT_TEMP=6
COMMUNICATE_EXTERNAL_TEMP=7
COMMUNICATE_HEATING_MODE=8
ACK_COMMUNICATE_LIVING_TEMP=24
ACK_COMMUNICATE_UPSTAIRS_TEMP=25
ACK_COMMUNICATE_BASEMENT_TEMP=26
ACK_COMMUNICATE_EXTERNAL_TEMP=27
ACK_COMMUNICATE_HEATING_MODE=28

#Heating mode
HEATING_MODE_RAD=0
HEATING_MODE_FLOOR=1
HEATING_MODE_RADFLOOR=3
HEATING_MODE_OFF=4


#Messaging states
WAIT_COMMAND_HEAD=0
RECEIVE_COMMAND=1

#	The class of the UI states
class Ui_State
	def initialize(name,description)
		@name = name
		@description = description
	end
	attr_accessor :description
	attr_accessor :name
end

class Ui_State_Machine
	def initialize
	
 #		Set the initial state

	  @state_comm_values = Ui_State.new("CommValues","Communicate environmental values towards the UI")
	  @state = @state_comm_values
	  @ui = UI_interface.new(SERIALPORT_NUM,PARITY,STOPBITS,BAUD,DATABITS)
	  
	end

#	The function evaluating ststes and performing necessary
#	transitions basd on the current value of sensors
	def state_change
	
	
	end

	def operate

	  while true
	    
	    state_change
	    
	    process_incoming_messages
	    
	    operate_state
	    
	  end
	  
	end

	def format_temp_param(temp)
	    if temp<0 
		negative = temp<0
		temp = -1*temp
	    end
	    retval = "%03d" % ((temp*10).round)
    	    if negative
    		retval = "-"+retval
    	    else
    		retval = "+"+retval
    	    end
    	    return retval
	end

	def operate_state
	
	  case @state.name
	  when	"CommValues"
	    sleep(1)
	    print "CommVal\n"
	    
	    print @ui.send_message(COMMUNICATE_LIVING_TEMP,format_temp_param(0.04587)),"\n"
    	    print @ui.send_message(COMMUNICATE_UPSTAIRS_TEMP,format_temp_param(0)),"\n"
    	    print @ui.send_message(COMMUNICATE_BASEMENT_TEMP,format_temp_param(26.78181)),"\n"
    	    print @ui.send_message(COMMUNICATE_EXTERNAL_TEMP,format_temp_param(-2.47457)),"\n"
    	    print @ui.send_message(COMMUNICATE_HEATING_MODE,HEATING_MODE_RADFLOOR),"\n"

	  end
	  
	end


	def process_incoming_messages
	  
	end

	def state_change
	  
	end
	
end	


class UI_interface
      def initialize(portnum,parity,stopbits,baud,databits)
	@sp = SerialPort.new(portnum)
	@sp.modem_params=({"parity"=>parity, "stop_bits"=>stopbits, "baud"=>baud, "data_bits"=>databits})
	@sp.sync = true
	@message_seq = 0

	@receive_sema = Mutex.new
	
	@send_buffer={}
	@incoming_message_buffer={}
	@answer_buffer={}
	
	@reader_thread=Thread.new do
	  Thread.current["thread_name"] = "Serial port reader thread"
	  message = ""
	  @messaging_state = WAIT_COMMAND_HEAD
  	  while true
	    case @messaging_state
	    when WAIT_COMMAND_HEAD
	      @sp.getc == MESSAGE_HEAD and @messaging_state = RECEIVE_COMMAND
	    when RECEIVE_COMMAND
	      char_read = @sp.getc
	      if char_read == MESSAGE_TERMINATOR
		host = message[0]
		seq = (message[1]-48)*100+(message[2]-48)*10+message[3]-48
		if host == HOST_ID
		  @receive_sema.synchronize { @send_buffer[seq] != nil and @answer_buffer[seq]=message }
		else
		  @incoming_message_buffer[seq]=message
		end
		@messaging_state = WAIT_COMMAND_HEAD
		message = ""
	      else
		message << char_read
	      end
	    end
	  end
	  Thread.exit()
	end
      end
      def send_message(command,parameter)
	message=""
	seq = @message_seq

#Incerement message seq 
	if @message_seq < 998
	  @message_seq+=1
	else
	  @message_seq=0
	end

#Create the message
	message << MESSAGE_HEAD << HOST_ID << seq/100+48 << (seq%100)/10+48 << (seq%10)+48 << command << parameter << MESSAGE_TERMINATOR
	@send_buffer[seq] = message
	write(message)
	if wait_for_ack(seq,command)
	  @send_buffer.delete(seq)
	  @answer_buffer.delete(seq)
	  return true
	else
	  @receive_sema.synchronize{@send_buffer.delete(seq)}
	  @answer_buffer.delete(seq)
	  return false
	end
      end

      def wait_for_ack(message_seq,command)
	answer = ""
	numtries = 0
	begin
	  sleep(0.01)
	  got_answer = @answer_buffer[message_seq] !=nil and @answer_buffer[message_seq][4] == command
	  numtries+=1
	end while !got_answer and numtries<500
	print numtries,"\n"
	return numtries<500
     end
      

      def write(message)
	message[-1] != MESSAGE_TERMINATOR and message << MESSAGE_TERMINATOR
	@sp.write(message)
      end
      
end

print "Starting up\n"
ui = Ui_State_Machine.new
ui.operate
