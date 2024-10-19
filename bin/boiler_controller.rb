#!/usr/bin/ruby
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

logger = Globals::ControllerLogger.new

logger.app_logger.level = Globals::BoilerLogger::INFO
logger.heating_logger.level = Logger::INFO

DRY_RUN = false

# Beginnning of main execution thread

Thread.current['thread_name'] = 'Main thread'

RobustThread.logger = logger.daemon_logger

daemonize = !ARGV.find_index('--daemon').nil?

pid = fork do
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

  # Create logger
  logger.app_logger.level = Globals::BoilerLogger::DEBUG unless\
  ARGV.find_index('--debug').nil?

  logger.app_logger.info('**************------------------------------***************')
  logger.app_logger.info('Boiler controller initializing')

  startup_fail = false
  begin
    # Create controller
    heating_control = HeatingController.new(config)
  rescue StandardError => e
    startup_fail = true
  end

  if !startup_fail
    logger.app_logger.info('Controller initialized - starting operation')

    RobustThread.new(label: 'Restapi thread') do
      Thread.current[:name] = 'Restapi Thread'
      Signal.trap('HUP', 'IGNORE')
      Signal.trap('TERM', 'IGNORE')
      # Create rest api
      Restapi.set :bind, config[:rest_serverip]
      Restapi.set :port, config[:rest_serverport]
      Restapi.set :myprivatekey, config[:rest_privatekey]
      Restapi.set :mycertfile, config[:rest_cert_file]
      Restapi.set :heatingconfig, config
      Restapi.set :heatingcontrol, heating_control
      Restapi.set :logger, logger

      class << Restapi.settings
        def server_settings
          {
            backend: BoilerThinBackend,
            private_key_file: settings.myprivatekey,
            cert_chain_file: settings.mycertfile,
            verify_peer: false
          }
        end
      end

      logger.app_logger.info('Starting restapi')
      Restapi.run!
      logger.app_logger.info('Restapi terminated')
    end

    # Log that the restapi webserver is running
    Thread.new do
      sleep(1) until Restapi.settings.running?
      logger.app_logger.info('Restapi startup complete')
    end

    RobustThread.new(label: 'Main daemon thread') do
      Thread.current[:name] = 'Main daemon'
      Signal.trap('HUP', 'IGNORE')

      begin
        heating_control.operate
      rescue StandardError => e
        logger.app_logger.fatal("Exception caught in main block: #{e.inspect}")
        logger.app_logger.fatal("Exception backtrace: #{e.backtrace.join("\n")}")
        config.shutdown_reason = Globals::FATAL_SHUTDOWN
        heating_control.shutdown
        logger.app_logger.info('Shutting down Restapi')
        Restapi.quit!
        exit
      end
      logger.app_logger.info('Shutting down Restapi')
      Restapi.quit!
    end
  else
    logger.app_logger.info('\nController startup failed - exiting')
    exit
  end
end

if daemonize
  Process.detach pid
else
  Process.wait
end
