#!/usr/local/rvm/rubies/ruby-2.3.0/bin/ruby
# frozen_string_literal: true

# Boiler control softvare

require '/usr/local/lib/boiler_controller/heating_controller'
require '/usr/local/lib/boiler_controller/restapi'
require 'robustthread'

# Config file paths
CONFIG_FILE_PATH = '/etc/boiler_controller/boiler_controller.yml'
TEST_CONTROL_FILE_PATH = '/etc/boiler_controller/boiler_test_controls.yml'

Thread.abort_on_exception = true

$stdout.sync = true

logger = BoilerLogger.new

logger.app_logger.level = Globals::BoilerLogger::INFO
logger.heating_logger.level = Logger::INFO

DRY_RUN = false

$low_floor_temp_mode = false

Signal.trap('TTIN') do
  puts "---------\n"
  Thread.list.each do |thread|
    puts "Thread name: #{thread[:name]} ID: #{thread.object_id.to_s(36)}"
    puts thread.backtrace.join("\n")
    puts "---------\n"
  end
  puts "---------\n"
end

Signal.trap('USR1') do
  puts 'USR1 signal caught - setting heating logging to '\
  'DEBUG, app logging to INFO'
  logger.app_logger.level = Globals::BoilerLogger::INFO
  logger.heating_logger.level = Logger::DEBUG
end

Signal.trap('USR2') do
  puts 'USR2 signal caught - setting all logging to INFO'
  logger.app_logger.level = Globals::BoilerLogger::INFO
  logger.heating_logger.level = Logger::INFO
end

Signal.trap('URG') do
  puts 'URG signal caught - setting all logging to DEBUG'
  logger.app_logger.level = Globals::BoilerLogger::DEBUG
  logger.heating_logger.level = Logger::DEBUG
end

# Beginnning of main execution thread

Thread.current['thread_name'] = 'Main thread'

RobustThread.logger = logger.daemon_logger

daemonize = !ARGV.find_index('--daemon').nil?

pid = fork do
=begin
  restapi_thread = Thread.new do
    $app_logger.info('Starting restapi')
    $BoilerRestapi.run!
  end
=end
  pidfile_index = ARGV.find_index('--pidfile')
  pidpath = if !pidfile_index.nil? && !ARGV[pidfile_index + 1].nil?
              ARGV[pidfile_index + 1]
            else
              Globals::PIDFILE
            end
  pidfile = File.new(pidpath, 'w')
  pidfile.write(Process.pid.to_s)
  pidfile.close

  config = Globals::Config.new(logger, CONFIG_FILE_PATH)

  config.pidpath = pidpath

  Signal.trap('TERM') do
    puts 'TERM signal caught - setting shutdown reason to NORMAL_SHUTDOWN'
    config.shutdown_reason = Globals::NORMAL_SHUTDOWN
  end

  RobustThread.new(label: 'Main daemon thread') do
    Thread.current[:name] = 'Main daemon'
    Signal.trap('HUP', 'IGNORE')

    logger.app_logger.level = Globals::BoilerLogger::DEBUG unless\
                        ARGV.find_index('--debug').nil?

    logger.app_logger.info('Boiler controller initializing')

    # Create controller
    boiler_control = HeatingController.new(config)
    logger.app_logger.info('Controller initialized - starting operation')

    begin
      boiler_control.operate
    rescue StandardError => e
      logger.app_logger.fatal('Exception caught in main block: ' + e.inspect)
      logger.app_logger.fatal('Exception backtrace: ' + e.backtrace.join("\n"))
      config.shutdown_reason = Globals::FATAL_SHUTDOWN
      boiler_control.shutdown
      # $BoilerRestapi.quit!
      exit
    end
    # $BoilerRestapi.quit!
  end
end

require '/usr/local/lib/boiler_controller/restapi'

if daemonize
  Process.detach pid
else
  Process.wait
end
