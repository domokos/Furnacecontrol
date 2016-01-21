#!/usr/local/rvm/rubies/ruby-2.1.5/bin/ruby
# Boiler control softvare

require "/usr/local/lib/boiler_controller/heating_controller"
require "robustthread"

Thread.abort_on_exception=true

$stdout.sync = true

$app_logger.level = Globals::BoilerLogger::INFO
$heating_logger.level = Logger::INFO

DRY_RUN = false
$shutdown_reason = Globals::NO_SHUTDOWN
$low_floor_temp_mode = false

Signal.trap("TTIN") do
  puts "---------\n"
  Thread.list.each do |thread|
    puts "Thread name: "+thread[:name].to_s+" ID: #{thread.object_id.to_s(36)}"
    puts thread.backtrace.join("\n")
    puts "---------\n"
  end
  puts "---------\n"
end

Signal.trap("USR1") do
  $app_logger.level = Globals::BoilerLogger::INFO
  $heating_logger.level = Logger::DEBUG
end

Signal.trap("USR2") do
  $app_logger.level = Globals::BoilerLogger::INFO
  $heating_logger.level = Logger::INFO
end

Signal.trap("URG") do
  $app_logger.level = Globals::BoilerLogger::DEBUG
  $heating_logger.level = Logger::DEBUG
end

# Beginnning of main execution thread

Thread.current["thread_name"] = "Starter thread"

RobustThread.logger = $daemon_logger

Signal.trap("TERM") do
  $shutdown_reason = Globals::NORMAL_SHUTDOWN
end

daemonize = ARGV.find_index("--daemon") != nil

pid = fork do
  main_rt = RobustThread.new(:label => "Main daemon thread") do

    Thread.current[:name] = "Main daemon"
    Signal.trap("HUP", "IGNORE")

    pidfile_index = ARGV.find_index("--pidfile")
    if pidfile_index != nil and ARGV[pidfile_index+1] != nil
      $pidpath = ARGV[pidfile_index+1]
    else
      $pidpath = Globals::PIDFILE
    end

    $app_logger.level = Globals::BoilerLogger::DEBUG if ARGV.find_index("--debug") != nil

    pidfile=File.new($pidpath,"w")
    pidfile.write(Process.pid.to_s)
    pidfile.close

    # Set the initial state
    boiler_control = Heating_controller.new(:Off,:Heat)
    $app_logger.info("Controller initialized - starting operation")

    begin
      boiler_control.operate
    rescue Exception => e
      $app_logger.fatal("Exception caught in main block: "+e.inspect)
      $app_logger.fatal("Exception backtrace: "+e.backtrace.join("\n"))
      $shutdown_reason = Globals::FATAL_SHUTDOWN
      boiler_control.shutdown
      exit
    end
  end
end

require "/usr/local/lib/boiler_controller/restapi"

if daemonize
  Process.detach pid
else
  Process.wait
end
