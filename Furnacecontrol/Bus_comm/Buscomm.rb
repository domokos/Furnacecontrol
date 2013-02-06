#!/usr/bin/ruby

$stdout.sync = true
require 'rubygems'
require 'serialport'
require 'thread'

MAX_MESSAGE_LENGTH = 15

# Messaging states
AWAITING_START_FRAME = 0
RECEIVING_MESSAGE = 1

#
# The number after which get_message is called while waiting for a character
# during transmission of a frame but recieving none that will cause
# it to reset: a timeout limit.
#
MESSAGE_TIMEOUT_COUNT_LIMIT = 500

# Messaging frame structure elements
START_FRAME = 0x55
END_FRAME = 0x5d
MESSAGE_ESCAPE = 0x7d

# Messaging error conditions
NO_ERROR = 0 # No error
NO_START_FRAME_RECEIVED = 1 # Expected message start frame, got something else => Ignoring the frame
MESSAGE_TOO_LONG = 2 #Receive buffer length exceeded
MESSAGING_TIMEOUT = 3 #Timeout occured
COMM_CRC_ERROR = 4  #Frame with CRC error received

# CRC generator polynomial
CRC16_POLYNOMIAL = 0x1021

#
# Command opcodes
#

# Set the value of a register
SET_REGISTER = 0
# Read the value of a register
READ_REGISTER = 1
# Identify a register by returning its description
IDENTTIFY_REGISTER = 2
# Reset the device to its basic state
RESET_DEVICE = 3
# Perform tests
COMM_TEST_REVERSE_MESSAGE = 4
# PING - master expects an echo and the same payload
PING = 5
# Set communication speed
SET_COMM_SPEED = 6


#
# COMMAND PARAMETERS
#
# Parameters of SET_COMM_SPEED

COMM_SPEED_300_L = 0
COMM_SPEED_1200_L = 1
COMM_SPEED_2400_L = 2
COMM_SPEED_4800_L = 3
COMM_SPEED_9600_L = 4
COMM_SPEED_14400_L = 5
COMM_SPEED_28800_L = 6
COMM_SPEED_300_H = 7
COMM_SPEED_1200_H = 8
COMM_SPEED_2400_H = 9
COMM_SPEED_4800_H = 10
COMM_SPEED_9600_H = 11
COMM_SPEED_14400_H = 12
COMM_SPEED_19200_H = 13
COMM_SPEED_28800_H = 14
COMM_SPEED_57600_H = 15


#
# Response opcodes
#

# The received message contais CRC error
# The message has a zero length payload. CRC follows the opcode
CRC_ERROR 0
# Command succesfully recieved response messge payload
# contains the information requested by the master
COMMAND_SUCCESS = 1
# Command succesfully recieved, execution of the
# requested operation failed, original status preserved or
# status undefined
COMMAND_FAIL = 2
# Response to a PING message - should contain the same
# message recieved in the PING
ECHO = 3


#/**********************************************************************************
# * The messaging format:
# * START_FRAME - 8 bits
# * SLAVE_ADDRESS - 8 bits
# * SEQ - 8 bits
# * OPCODE - 8 bits
# * PARAMERER - arbitrary number of bytes
# * CRC - 2*8 bits calculated for the data between start and end frame
# * END_FRAME - 8 bits
# *
# *  * The SEQ field holds a message sequence number
# *      SEQ
# *      Index must point to the last parameter byte
# ***********************************************************************************/

# The buffer indexes
SLAVE_ADDRESS = 0
SEQ = 1
OPCODE = 2
PARAMETER_START = 3

class Buscomm
  def initialize(portnum,parity,stopbits,baud,databits)
    @sp = SerialPort.new(portnum)
    set_comm_paremeters(portnum,parity,stopbits,baud,databits)    
    @sp.sync = true
    @message_seq = 0

    @send_buffer={}
    @incoming_message_buffer={}
    @answer_buffer={}

  end

  def send_message(slave_address,opcode,parameter)
    message=""
    seq = @message_seq
  
  #Incerement message seq 
    @message_seq < 255 ? @message_seq+=1 : @message_seq=0
  
    
    
  #Create the message
    message << START_FRAME << slave_address << seq << opcode << parameter << END_FRAME
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

  def init_reader_thread
    @reader_thread=Thread.new do
      Thread.current["thread_name"] = "Bus reader thread"
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

  def set_comm_paremeters(portnum,parity,stopbits,baud,databits)
    @sp.modem_params=({"parity"=>parity, "stop_bits"=>stopbits, "baud"=>baud, "data_bits"=>databits})
  end
          
  def set_comm_speed(baud)
    @sp.modem_params=({"baud"=>baud})
  end
end