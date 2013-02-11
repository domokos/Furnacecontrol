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
    @sp.flow_control=SerialPort::NONE
    comm_direction(MASTER_SENDS)
    @sp.sync = true
    @sp.binmode
    @message_seq = 0
    @busmutex = Mutex.new
    @serial_read_mutex = Mutex.new 
    @serial_response_buffer=[]
  end

  def send_message(slave_address,opcode,parameter)
# Communicate in a synchronized manner 
# only one communication session is allowed on the bus so 
# synchronize it across potentially multiple Buscomm objects
# to make it Thread safe
  @busmutex.synchronize do
    message=""
    seq = @message_seq
  
  #Incerement message seq 
    @message_seq < 255 ? @message_seq+=1 : @message_seq=0
  
  #Create the message
    message << slave_address << seq << opcode << parameter
    crc = crc16(message)
    message << ( crc >> 8).chr << (crc & 0xff).chr
    escape(message)
    
  # Write the message to the bus
    framed_message = ""
    framed_message << START_FRAME << message << END_FRAME  
    
    comm_direction(MASTER_SENDS)
    @sp.write(framed_message)
    
    
  # Wait for the response and return it to the caller
    comm_direction(MASTER_LISTENS)
  # Flush the serial port input buffer
    @sp.sync
    
    start_serial_reader_thread
    return wait_for_response
    stop_serial_reader_thread
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
     byte_recieved = 0
     response_state = AWAITING_START_FRAME
     escaped = false
     timeout_counter = 0
     while true
       @serial_read_mutex.synchronize { byte_recieved = @serial_response_buffer.shift }
       if byte_recieved == nil
         # Save the processor
         timeout_counter += 1
         timeout_counter > RESPONSE_RECIEVE_TIMEOUT and return {"Return_code" => MESSAGING_TIMEOUT, "Content" => nil}
         sleep 0.001
         next
       end
       # Character recieved - process it   
       case response_state
       when AWAITING_START_FRAME
         byte_recieved  == START_FRAME and response_state = RECEIVING_MESSAGE
       when RECEIVING_MESSAGE
         if byte_recieved == MESSAGE_ESCAPE && !escaped
           escaped = true
         elsif byte_recieved != END_FRAME || escaped
           escaped = false
           message << char_recieved
         else
           # End frame is recieved evaluate the recieved message
           message << byte_recieved
           if !check_crc(message) or message[OPCODE] == CRC_ERROR
           return {"Return_code" => COMM_CRC_ERROR, "Content" => message}
           else
           return {"Return_code" => NO_ERROR, "Content" => message}
           end
         end
       end
     end
   end
   
  def start_serial_reader_thread
    @reader_thread = Thread.new do
      @serial_read_mutex.synchronize do @serial_response_buffer=[] end
      while true
        byte_read = @sp.getbyte
        print byte_read,","
        @serial_read_mutex.synchronize do
          @serial_response_buffer.push(byte_read)
          # Discard characers not read for a long time
          shift @serial_response_buffer if @serial_response_buffer.size > SERIAL_RECIEVE_BUFFER_LIMIT 
        end
     end
    end
  end

  def stop_serial_reader_thread
    @reader_thread.kill
  end
  
  def is_master_sending
    return @sp.rts
  end
  
  def comm_direction(direction)
    @sp.rts = direction
  end
    
  def escape(message)
    escaped = ""
    message.each_char do |c|
      if c == MESSAGE_ESCAPE  or c == END_FRAME
        escaped << MESSAGE_ESCAPE << c  
      else 
        escaped << c
      end
    end
    return escaped
  end
  
  def flip_bits(char)
    retval = char.unpack('B*').pack('b*').unpack("C")[0] 
    return retval 
  end

  # CRC16 CCITT (0xFFFF) checksum
  def crc16(buf)
    crc = 0xffff
    tmp = []
    buf.each_char do |b|
      crc = ((crc << 8) & 0xffff) ^ CRC_LOOKUP[(crc >> 8) ^ flip_bits(b) & 0xff]
    end
    return crc
  end

  CRC_LOOKUP = [
    0x0000, 0x1021, 0x2042, 0x3063, 0x4084, 0x50a5, 0x60c6, 0x70e7,
    0x8108, 0x9129, 0xa14a, 0xb16b, 0xc18c, 0xd1ad, 0xe1ce, 0xf1ef,
    0x1231, 0x0210, 0x3273, 0x2252, 0x52b5, 0x4294, 0x72f7, 0x62d6,
    0x9339, 0x8318, 0xb37b, 0xa35a, 0xd3bd, 0xc39c, 0xf3ff, 0xe3de,
    0x2462, 0x3443, 0x0420, 0x1401, 0x64e6, 0x74c7, 0x44a4, 0x5485,
    0xa56a, 0xb54b, 0x8528, 0x9509, 0xe5ee, 0xf5cf, 0xc5ac, 0xd58d,
    0x3653, 0x2672, 0x1611, 0x0630, 0x76d7, 0x66f6, 0x5695, 0x46b4,
    0xb75b, 0xa77a, 0x9719, 0x8738, 0xf7df, 0xe7fe, 0xd79d, 0xc7bc,
    0x48c4, 0x58e5, 0x6886, 0x78a7, 0x0840, 0x1861, 0x2802, 0x3823,
    0xc9cc, 0xd9ed, 0xe98e, 0xf9af, 0x8948, 0x9969, 0xa90a, 0xb92b,
    0x5af5, 0x4ad4, 0x7ab7, 0x6a96, 0x1a71, 0x0a50, 0x3a33, 0x2a12,
    0xdbfd, 0xcbdc, 0xfbbf, 0xeb9e, 0x9b79, 0x8b58, 0xbb3b, 0xab1a,
    0x6ca6, 0x7c87, 0x4ce4, 0x5cc5, 0x2c22, 0x3c03, 0x0c60, 0x1c41,
    0xedae, 0xfd8f, 0xcdec, 0xddcd, 0xad2a, 0xbd0b, 0x8d68, 0x9d49,
    0x7e97, 0x6eb6, 0x5ed5, 0x4ef4, 0x3e13, 0x2e32, 0x1e51, 0x0e70,
    0xff9f, 0xefbe, 0xdfdd, 0xcffc, 0xbf1b, 0xaf3a, 0x9f59, 0x8f78,
    0x9188, 0x81a9, 0xb1ca, 0xa1eb, 0xd10c, 0xc12d, 0xf14e, 0xe16f,
    0x1080, 0x00a1, 0x30c2, 0x20e3, 0x5004, 0x4025, 0x7046, 0x6067,
    0x83b9, 0x9398, 0xa3fb, 0xb3da, 0xc33d, 0xd31c, 0xe37f, 0xf35e,
    0x02b1, 0x1290, 0x22f3, 0x32d2, 0x4235, 0x5214, 0x6277, 0x7256,
    0xb5ea, 0xa5cb, 0x95a8, 0x8589, 0xf56e, 0xe54f, 0xd52c, 0xc50d,
    0x34e2, 0x24c3, 0x14a0, 0x0481, 0x7466, 0x6447, 0x5424, 0x4405,
    0xa7db, 0xb7fa, 0x8799, 0x97b8, 0xe75f, 0xf77e, 0xc71d, 0xd73c,
    0x26d3, 0x36f2, 0x0691, 0x16b0, 0x6657, 0x7676, 0x4615, 0x5634,
    0xd94c, 0xc96d, 0xf90e, 0xe92f, 0x99c8, 0x89e9, 0xb98a, 0xa9ab,
    0x5844, 0x4865, 0x7806, 0x6827, 0x18c0, 0x08e1, 0x3882, 0x28a3,
    0xcb7d, 0xdb5c, 0xeb3f, 0xfb1e, 0x8bf9, 0x9bd8, 0xabbb, 0xbb9a,
    0x4a75, 0x5a54, 0x6a37, 0x7a16, 0x0af1, 0x1ad0, 0x2ab3, 0x3a92,
    0xfd2e, 0xed0f, 0xdd6c, 0xcd4d, 0xbdaa, 0xad8b, 0x9de8, 0x8dc9,
    0x7c26, 0x6c07, 0x5c64, 0x4c45, 0x3ca2, 0x2c83, 0x1ce0, 0x0cc1,
    0xef1f, 0xff3e, 0xcf5d, 0xdf7c, 0xaf9b, 0xbfba, 0x8fd9, 0x9ff8,
    0x6e17, 0x7e36, 0x4e55, 0x5e74, 0x2e93, 0x3eb2, 0x0ed1, 0x1ef0
    ]

    MASTER_SENDS = 1
    MASTER_LISTENS = 0
end

#Parameters
SERIALPORT_NUM=0
PARITY=0
STOPBITS=1
BAUD=4800
DATABITS=8

#port = SerialPort.new(0)
#port.modem_params=({"parity"=>0, "stop_bits"=>1, "baud"=>4800, "data_bits"=>8})
#port.rts = Buscomm::MASTER_SENDS

#while true
# port.write(START_FRAME)
# port.write(1)
# port.write(PING)
# port.write(0x1a)
# port.write(0x36)
# port.write(END_FRAME)
#end



my_comm = Buscomm.new(SERIALPORT_NUM,PARITY,STOPBITS,BAUD,DATABITS)

while true
  print my_comm.send_message(1,PING,"ping"),"\n"
end
