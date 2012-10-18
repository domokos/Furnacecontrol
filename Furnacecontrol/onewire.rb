#!/usr/bin/ruby

#
#V1: 13 Oct 2010
#	Owserver based one wire communication
#
#

require "socket"

$Onewire_Requires_Furnace_Restart = false
$Owserver_Exception = nil
$Owserver_Restart_Try_Count = 0

module Onewire

class Owclient
  def present
    begin
      serversock=TCPSocket.new('localhost',4304)

      version=[0,0,0,0]
      payloadsize=[0,0,0,0]
      type=[0,0,0,6]
      controllflags=[0,0,0,0]
      respsize=[0,0,16,0]
      offset=[0,0,0,0]
      payload=@path+"\0"
      payloadsize=[0,0,0,payload.length]

      message=version.pack("cccc")+payloadsize.pack("cccc")+type.pack("cccc")+controllflags.pack("cccc")+respsize.pack("cccc")+offset.pack("cccc")+payload

      serversock.write(message)

      start_time = Time.now.to_f
      
      while (response = serversock.recv(4096))
	  break if Time.now.to_f > start_time+6
	  next if response == ""
	  next if response.unpack("@4l")[0] == -1
	  break
      end
      
      raise "Limit for owserver to respond expired in present" if Time.now.to_f > start_time+6

      retval = response[8,4].reverse.unpack("l")[0]

      serversock.close
      return retval == 0
    rescue Exception => $Owserver_Exception
      return false
    end
  end

  def read_path
    connection_retry_count=0
    begin
      serversock=TCPSocket.new('localhost',4304)

      version=[0,0,0,0]
      payloadsize=[0,0,0,0]
      type=[0,0,0,2]
      controllflags=[0,0,0,0]
      respsize=[0,0,16,0]
      offset=[0,0,0,0]
      payload=@path+"\0"
      payloadsize=[0,0,0,payload.length]

      message=version.pack("cccc")+payloadsize.pack("cccc")+type.pack("cccc")+controllflags.pack("cccc")+respsize.pack("cccc")+offset.pack("cccc")+payload

      serversock.write(message)

      start_time = Time.now.to_f
      
      while (response = serversock.recv(4096))
	  break if Time.now.to_f > start_time+6
	  next if response == ""
	  next if response.unpack("@4l")[0] == -1
	  break
      end

      raise "Limit for owserver for responding expired in read" if Time.now.to_f > start_time+6

      version = response.unpack("N")[0]
      payloadlength = response[4,4].reverse.unpack("l")[0]
      retval = response[8,4].reverse.unpack("l")[0]
      controlflags = response.unpack("@12N")[0]
      size = response[16,4].reverse.unpack("l")[0]
      offset = response[20,4].reverse.unpack("l")[0]
      payload = response[25,payloadlength]

      raise "Error in reply from owserver in read, ERRNO: "+retval.to_s if retval < 0
      raise "Error in reply from owserver in read, No data in response:" if payloadlength == 0
      raise "Error in reply from owserver in read, Negative payloadlength:"+payloadlength.to_s if payloadlength < 0

      serversock.close
      $Owserver_Restart_Try_Count = 0
      return payload    
    rescue Exception => $Owserver_Exception
      connection_retry_count += 1
      if connection_retry_count == 10
	Onewire.do_owserver_rescue
	connection_retry_count = 0
      end
      retry
    end
  end
  
  def write_path(value)
    connection_retry_count=0
    begin
      serversock=TCPSocket.new('localhost',4304)

      version=[0,0,0,0]
      payloadsize=[0,0,0,0]
      type=[0,0,0,3]
      controllflags=[0,0,0,0]
      respsize=[0,0,0,1]
      offset=[0,0,0,0]
      payload=@path+"\0"+value
      payloadsize=[0,0,0,payload.length]

      message=version.pack("cccc")+payloadsize.pack("cccc")+type.pack("cccc")+controllflags.pack("cccc")+respsize.pack("cccc")+offset.pack("cccc")+payload

      serversock.write(message)

      start_time = Time.now.to_f
      
      while (response = serversock.recv(4096))
	  break if Time.now.to_f > start_time+6
	  next if response == ""
	  next if response.unpack("@4l")[0] == -1
	  break
      end

      raise "Limit for owserver for responding expired in write" if Time.now.to_f > start_time+6

      version = response.unpack("N")[0]
      payloadlength = response[4,4].reverse.unpack("l")[0]
      retval = response[8,4].reverse.unpack("l")[0]
      controlflags = response.unpack("@12N")[0]
      size = response[16,4].reverse.unpack("l")[0]
      offset = response[20,4].reverse.unpack("l")[0]

      raise "Error in reply from owserver in write, ERRNO: "+retval.to_s if retval != 0

      serversock.close
      $Owserver_Restart_Try_Count = 0
    rescue Exception => $Owserver_Exception
      connection_retry_count += 1
      if connection_retry_count == 10
	Onewire.do_owserver_rescue
	connection_retry_count = 0
     end
      retry
    end
  end

  def write(path,value)
      tmp_path=@path

      @path=path
      write_path(value)
      @path = tmp_path
  end

end


# The general class of the addressable switches - not to be instatntiated directly
class DS_240X < Owclient
  attr_accessor :name, :id, :location, :do_tests
  attr_reader :state

  def initialize(name,location,id,do_tests)
	  @name = name
	  @id = id
	  @location = location
	  @do_tests = do_tests
	  @path = nil
	  
	  @state="unknown"

	  !@do_tests and off
	  @state = "off"
  end

  def close  
    off
  end

  def open
    on
  end
  
  def on
    if @state != "on"
      !@do_tests and write_path("1")
      @state = "on"
    end
  end

  def off
    if @state != "off"
      !@do_tests and write_path("0")
      @state = "off"
    end
  end
end

# The class of the single addressable switches
class DS_2405 < DS_240X
  attr_accessor :name, :id, :location, :pioid, :do_tests
  attr_reader :state

  def initialize(name,location,id,do_tests)
    @name = name
    @id = id
    @location = location
    @pioid = pioid
    @do_tests = do_tests
    @path = "/" + @id + "/PIO"
    
    @state="unknown"

    !@do_tests and off
    @state = "off"
  end
end


# The class of the dual addressable switches
class DS_2406 < DS_240X
  attr_accessor :name, :id, :location, :pioid, :do_tests
  attr_reader :state

  def initialize(name,location,id,pioid,do_tests)
    @name = name
    @id = id
    @location = location
    @pioid = pioid
    @do_tests = do_tests
    @path = "/" + @id + "/PIO." + @pioid
    
    @state="unknown"

    !@do_tests and off
    @state = "off"
  end
end

# The class of the old temperature sensors
class DS_18S20 < Owclient
  attr_accessor :name, :id, :location, :min_conversion_delay

  def initialize(name,location,id,min_conversion_delay)
    @name = name
    @id = id
    @location = location
    @min_conversion_delay = min_conversion_delay
    @path = "/" + @id + "/temperature"
    @delay_timer = Timer.new(@min_conversion_delay,"Delay_timer18S20")
  end

  def temp
    if !@delay_timer.expired?
      return @lasttemp
    else
      @lasttemp = read_path.to_f
      @delay_timer.reset
      return @lasttemp
    end
  end

end

# The class of the programmable temperature sensors
class DS_18B20 < Owclient
  attr_accessor :name, :id, :location, :min_conversion_delay, :precision
  
  def initialize(name,location,id,precision,min_conversion_delay)
    @name = name
    @id = id
    @precision = precision
    @location = location
    @min_conversion_delay = min_conversion_delay
    @dirpath = "/" + @id
    @path9 = "/" + @id + "/temperature9"
    @path10 = "/" + @id + "/temperature10"
    @path11 = "/" + @id + "/temperature11"
    @path12 = "/" + @id + "/temperature12"
    @delay_timer = Timer.new(@min_conversion_delay,"Delay_timer18B20")
  end

  def temp
    if !@delay_timer.expired? and @lasttemp != nil
      return @lasttemp
    else
      case @precision
	when "9"
		@path = @path9
	when "10"
		@path = @path10
	when "11"
		@path = @path11
	else
		@path = @path12
      end
      @lasttemp = read_path.to_f
      @delay_timer.reset
      return @lasttemp
    end
  end

  def set_precision(precision)
    @precision = precision
  end

end

def Onewire.do_owserver_rescue
  puts "Exception message: "+$Owserver_Exception.inspect
  $Onewire_Requires_Furnace_Restart = true
  $Owserver_Restart_Try_Count += 1
  system("/etc/init.d/owserver stop 2>/dev/null >/dev/null")
  if ($Owserver_Restart_Try_Count / 10).to_i
    sleep 10
  else
    sleep 1
  end
  if ($Owserver_Restart_Try_Count > 30)
    abort("Cannot handle owserver unavailability")
  end
  system("/etc/init.d/owserver start 2>/dev/null >/dev/null")
  sleep 1
end

#	Set the appropriate chahing modes of the owfs
def Onewire.set_caching(volatile,stable,serial,presence,directory,server)
	control_dev = Owclient.new
	$debuglevel > 1 and puts "Setting owfs caching mode"
	control_dev.write("/settings/timeout/volatile",volatile)
	control_dev.write("/settings/timeout/stable",stable)
	control_dev.write("/settings/timeout/serial",serial)
	control_dev.write("/settings/timeout/presence",presence)
	control_dev.write("/settings/timeout/directory",directory)
	control_dev.write("/settings/timeout/server",server)
end

end