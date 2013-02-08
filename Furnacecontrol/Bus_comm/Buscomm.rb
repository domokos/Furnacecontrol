#!/usr/bin/ruby

$stdout.sync = true
require 'rubygems'
require 'serialport'
require 'thread'

MAX_MESSAGE_LENGTH = 15
SERIAL_RECIEVE_BUFFER_LIMIT = 100
RESPONSE_RECIEVE_TIMEOUT = 3000

# Message recieving states
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
CRC_ERROR = 0
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
# CRC - 2*8 bits calculated for the data including start frame and the last byte of parameter
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
    @busmutex = Mutex.new
    @serial_read_mutex = Mutex.new 

    @serial_response_buffer=[]
    init_serial_reader_thread
  end

  def send_message(slave_address,opcode,parameter)
# Communicate in a synchronized manner 
# only one communication session is allowed on the bus so 
# synchronize it to make it Thread safe
  @busmutex.sychronize do
    message=""
    seq = @message_seq
  
  #Incerement message seq 
    @message_seq < 255 ? @message_seq+=1 : @message_seq=0
  
  #Create the message
    message << START_FRAME << slave_address << seq << opcode << parameter
    message << crc16(message)
    escape(message)
    mesage << END_FRAME

  # Write the message to the bus 
    @sp.write(message)

  # Wait for the response and return it to the caller
    return wait_for_response
  end 
 end

 def ping(slave_address)
   (response = send_message(slave_address,PING,"PING")) == nil and return nil
   return response[OPCODE] == ECHO
 end
 
 def set_comm_paremeters(portnum,parity,stopbits,baud,databits)
    @sp.modem_params=({"parity"=>parity, "stop_bits"=>stopbits, "baud"=>baud, "data_bits"=>databits})
 end
          
 def set_comm_speed(baud)
    @sp.modem_params=({"baud"=>baud})
 end
  
private

  def wait_for_response
     message = ""
     response_state = AWAITING_START_FRAME
     escaped = false
     timeout_counter = 0
     while true
       @serial_read_mutex.synchronize { char_recieved = @serial_response_buffer.shift }
       if char_recieved == nil
         # Save the processor
         timeout_counter += 1
         timeout_counter > RESPONSE_RECIEVE_TIMEOUT and return nil
         sleep 0.001
         break
       end
    # Character recieved - process it   
       case response_state
       when AWAITING_START_FRAME
         char_recieved  == START_FRAME and response_state = RECEIVING_MESSAGE
       when RECEIVING_MESSAGE
         if char_recieved == MESSAGE_ESCAPE && !escaped
           escaped = true
         elsif char_recieved != END_FRAME || escaped
           escaped = false
           message << char_recieved
         else
           # End frame is recieved evaluate the recieved message
           message << char_recieved
           if !check_crc(message) or message[OPCODE] == CRC_ERROR
             return nil
           else
             return message
           end
         end
       end
     end
   end
   
  def init_serial_reader_thread
    @reader_thread = Thread.new do
      char_read = @sp.getc
      @serial_read_mutex.synchronize do
        @serial_response_buffer.push(char_read)
        # Discard characers not read for a long time
        shift @serial_response_buffer if @serial_response_buffer.size > SERIAL_RECIEVE_BUFFER_LIMIT 
      end
     end
  end
  
  def escape(message)
    message.each_char do |c|
      if c == MESSAGE_ESCAPE  or c == END_FRAME
        escaped << MESSAGE_ESCAPE << c  
      else 
        escaped << c
      end
    end
    escaped
  end
  
  def flipeed(byte)
    bye.unpack('B*').pack('C')
  end

  def crc16(buf)
    crc = 0x00
    buf.each_byte do |b|
      crc = ((crc >> 8) & 0xff) ^ CRC_LOOKUP[(crc ^ flipped(b)) & 0xff]
    end
    crc
  end

  CRC_LOOKUP = [
    0x0000, 0xC0C1, 0xC181, 0x0140, 0xC301, 0x03C0, 0x0280, 0xC241,
    0xC601, 0x06C0, 0x0780, 0xC741, 0x0500, 0xC5C1, 0xC481, 0x0440,
    0xCC01, 0x0CC0, 0x0D80, 0xCD41, 0x0F00, 0xCFC1, 0xCE81, 0x0E40,
    0x0A00, 0xCAC1, 0xCB81, 0x0B40, 0xC901, 0x09C0, 0x0880, 0xC841,
    0xD801, 0x18C0, 0x1980, 0xD941, 0x1B00, 0xDBC1, 0xDA81, 0x1A40,
    0x1E00, 0xDEC1, 0xDF81, 0x1F40, 0xDD01, 0x1DC0, 0x1C80, 0xDC41,
    0x1400, 0xD4C1, 0xD581, 0x1540, 0xD701, 0x17C0, 0x1680, 0xD641,
    0xD201, 0x12C0, 0x1380, 0xD341, 0x1100, 0xD1C1, 0xD081, 0x1040,
    0xF001, 0x30C0, 0x3180, 0xF141, 0x3300, 0xF3C1, 0xF281, 0x3240,
    0x3600, 0xF6C1, 0xF781, 0x3740, 0xF501, 0x35C0, 0x3480, 0xF441,
    0x3C00, 0xFCC1, 0xFD81, 0x3D40, 0xFF01, 0x3FC0, 0x3E80, 0xFE41,
    0xFA01, 0x3AC0, 0x3B80, 0xFB41, 0x3900, 0xF9C1, 0xF881, 0x3840,
    0x2800, 0xE8C1, 0xE981, 0x2940, 0xEB01, 0x2BC0, 0x2A80, 0xEA41,
    0xEE01, 0x2EC0, 0x2F80, 0xEF41, 0x2D00, 0xEDC1, 0xEC81, 0x2C40,
    0xE401, 0x24C0, 0x2580, 0xE541, 0x2700, 0xE7C1, 0xE681, 0x2640,
    0x2200, 0xE2C1, 0xE381, 0x2340, 0xE101, 0x21C0, 0x2080, 0xE041,
    0xA001, 0x60C0, 0x6180, 0xA141, 0x6300, 0xA3C1, 0xA281, 0x6240,
    0x6600, 0xA6C1, 0xA781, 0x6740, 0xA501, 0x65C0, 0x6480, 0xA441,
    0x6C00, 0xACC1, 0xAD81, 0x6D40, 0xAF01, 0x6FC0, 0x6E80, 0xAE41,
    0xAA01, 0x6AC0, 0x6B80, 0xAB41, 0x6900, 0xA9C1, 0xA881, 0x6840,
    0x7800, 0xB8C1, 0xB981, 0x7940, 0xBB01, 0x7BC0, 0x7A80, 0xBA41,
    0xBE01, 0x7EC0, 0x7F80, 0xBF41, 0x7D00, 0xBDC1, 0xBC81, 0x7C40,
    0xB401, 0x74C0, 0x7580, 0xB541, 0x7700, 0xB7C1, 0xB681, 0x7640,
    0x7200, 0xB2C1, 0xB381, 0x7340, 0xB101, 0x71C0, 0x7080, 0xB041,
    0x5000, 0x90C1, 0x9181, 0x5140, 0x9301, 0x53C0, 0x5280, 0x9241,
    0x9601, 0x56C0, 0x5780, 0x9741, 0x5500, 0x95C1, 0x9481, 0x5440,
    0x9C01, 0x5CC0, 0x5D80, 0x9D41, 0x5F00, 0x9FC1, 0x9E81, 0x5E40,
    0x5A00, 0x9AC1, 0x9B81, 0x5B40, 0x9901, 0x59C0, 0x5880, 0x9841,
    0x8801, 0x48C0, 0x4980, 0x8941, 0x4B00, 0x8BC1, 0x8A81, 0x4A40,
    0x4E00, 0x8EC1, 0x8F81, 0x4F40, 0x8D01, 0x4DC0, 0x4C80, 0x8C41,
    0x4400, 0x84C1, 0x8581, 0x4540, 0x8701, 0x47C0, 0x4680, 0x8641,
    0x8201, 0x42C0, 0x4380, 0x8341, 0x4100, 0x81C1, 0x8081, 0x4040
  ]

  
end