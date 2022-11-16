# frozen_string_literal: true

require 'sinatra/base'
require 'thin'
require 'yaml'

# The TCP backend of the API
class BoilerThinBackend < ::Thin::Backends::TcpServer
  def initialize(host, port, options)
    super(host, port)
    @ssl = false
    @ssl_options = options
  end
end

# Class of the Rest API
class Restapi < Sinatra::Base
  HTTP_OK = 200
  HTTP_BAD_REQUEST = 400
  HTTP_NOT_FOUND = 404
  # Setup the webserver for the rest interface
  configure do
    set :environment, :production
    set :server, 'thin'
    disable :traps
  end

  def initialize
    super
    # Wait 1` secs` before serving non-essential requests to avoid nil class exceptions
    @startup_timer = Globals::TimerSec.new(10, 'Rest API startup timer')

    # Perform initial temperature read
    @startup_timer.reset
  end

  get '/config:itemname' do
    paramname = params['itemname'][1, 99].to_sym
    settings.heatingconfig[paramname].to_s
  end

  get '/current:itemname' do
    return 400 unless @startup_timer.expired?

    case params['itemname']
    when ':living_temp'
      settings.heatingcontrol.living_thermostat.temp.round(2).to_s
    when ':upstairs_temp'
      settings.heatingcontrol.upstairs_thermostat.temp.round(2).to_s
    when ':basement_temp'
      settings.heatingcontrol.basement_thermostat.temp.round(2).to_s
    when ':external_temp'
      settings.heatingcontrol.mode_thermostat.temp.round(2).to_s
    when ':dhw_temp'
      settings.heatingcontrol.hw_thermostat.temp.round(2).to_s
    when ':mixer_output_temp'
      settings.heatingcontrol.mixer_controller.temp.round(2).to_s
    when ':mixer_target'
      settings.heatingcontrol.mixer_controller.target_temp.round(2).to_s
    when ':return_temp'
      settings.heatingcontrol.heat_return_temp.round(2).to_s
    when ':output_temp'
      settings.heatingcontrol.output_temp.round(2).to_s
    when ':state'
      settings.heatingcontrol.state_history.last[:state].to_s
    when ':power'
      settings.heatingcontrol.state_history.last[:power].to_s
    when ':hp_outgoing_temp'
      settings.heatingcontrol.buffer_heater.heatpump.forward_temp.to_s
    when ':hp_target_temp'
      settings.heatingcontrol.buffer_heater.heatpump.heating_targettemp.to_s
    when ':hp_pump_rpm'
      settings.heatingcontrol.buffer_heater.heatpump.pump_rpm.to_s
    when ':hp_compressor_rpm'
      settings.heatingcontrol.buffer_heater.heatpump.compressor_rpm.to_s
    when ':hp_power'
      settings.heatingcontrol.buffer_heater.heatpump.power.to_s
    else
      HTTP_NOT_FOUND
    end
  end

  get '/shutdown' do
    settings.heatingconfig.shutdown_reason = Globals::NORMAL_SHUTDOWN
    200
  end

  get '/log:itemname' do
    case params['itemname']
    when ':on'
      settings.logger.app_logger.level = Globals::BoilerLogger::DEBUG
      settings.logger.heating_logger.level = Logger::DEBUG
      settings.logger.app_logger.info('Logging turned on')
      HTTP_OK
    when ':off'
      settings.logger.app_logger.level = Globals::BoilerLogger::INFO
      settings.logger.heating_logger.level = Logger::INFO
      settings.logger.app_logger.info('Logging turned off')
      HTTP_OK
    else
      'No such endpoint'
    end
  end

  patch '/reload' do
    settings.heatingcontrol.reload
    settings.logger.app_logger.info('Config reloaded')
    HTTP_OK
  end
end
