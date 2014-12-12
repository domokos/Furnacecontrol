

require "robustthread"

module Globals

  BOILER_LOGFILE = "/var/log/boiler_controller/boiler_controller.log"
  HEATING_LOGFILE = "/var/log/boiler_controller/boiler_heating.log"
  DAEMON_LOGFILE = "/var/log/boiler_controller/boiler_daemonlog.log"
  PIDFILE = "/var/run/boiler_controller/boiler_controller.pid"

  #Config file paths
  CONFIG_FILE_PATH = "/etc/boiler_controller/boiler_controller.yml"
  TEST_CONTROL_FILE_PATH = "/etc/boiler_controller/boiler_test_controls.yml"

  
  NO_SHUTDOWN = "No Shutdown"
  NORMAL_SHUTDOWN = "Normal Shutdown"
  FATAL_SHUTDOWN = "Shutdown on Fatal Error"
  
  
  applogfile = File.new(BOILER_LOGFILE,'a+')
  applogfile.sync = true
  $app_logger = Logger.new(applogfile, 6 , 1000000)
  
  $app_logger.formatter = proc { |severity, datetime, progname, msg|
    if caller[4].class == String
      "#{datetime.to_s.sub!(/^(.*) \+.*$/,'\1')} #{severity} #{caller[4].sub!(/^.*\/(.*)$/,'\1')} #{msg}\n"
    else
      "#{datetime.to_s.sub!(/^(.*) \+.*$/,'\1')} #{severity} #{caller[4]} #{msg}\n"
    end
    }

  heatinglogfile = File.new(BOILER_LOGFILE,'a+')
  heatinglogfile.sync = true
          
  $heating_logger = Logger.new(heatinglogfile, 6, 1000000)
  $heating_logger.formatter = proc { |severity, datetime, progname, msg|
      "#{msg}\n"
  }
    
  daemonlogfile = File.new(BOILER_LOGFILE,'a+')
  daemonlogfile.sync = true

  $daemon_logger = Logger.new(daemonlogfile, 6, 1000000)
  $daemon_logger.formatter = proc { |severity, datetime, progname, msg|
    if caller[4].class == String
      "#{datetime.to_s.sub!(/^(.*) \+.*$/,'\1')} #{severity} #{caller[4].sub!(/^.*\/(.*)$/,'\1')} #{msg}\n"
    else
      "#{datetime.to_s.sub!(/^(.*) \+.*$/,'\1')} #{severity} #{caller[4]} #{msg}\n"
    end
   }
      
 
# A Timer class for timing whole seconds
class TimerSec
  def initialize(sec_to_sleep,name)
    @name = name
    @sec_to_sleep = sec_to_sleep
    @timer_thread = nil
    @sec_left = 0
  end
  
  def start
    @sec_left = @sec_to_sleep
    @timer_thread = Thread.new do
      Thread.current["thread_name"] = @name
      while @sec_left > 0
        sleep(1)
        @sec_left = @sec_left - 1
      end
    end
  end
  
  def sec_left()
    return @sec_left
  end
  
  def expired?
    return @sec_left == 0
  end

  def reset
      stop
      start
  end
    
  def stop
    @timer_thread != nil and @timer_thread.kill
    @timer_thread = nil
    @sec_left=0
  end
end

# A general timer
class TimerGeneral
  def initialize(amount_to_sleep,name)
    @name = name
    @amount_to_sleep = amount_to_sleep
    @timer_thread = nil
  end
  
  def start
    @timer_thread = Thread.new do
      Thread.current["thread_name"] = @name
        sleep @amount_to_sleep
      end
  end
  
  def expired?
    @timer_thread == nil or @timer_thread.stop?
  end

  def reset
      stop
      start
  end
    
  def stop
        @timer_thread != nil and @timer_thread.kill
        @timer_thread = nil
        @sec_left=0
  end
end

end