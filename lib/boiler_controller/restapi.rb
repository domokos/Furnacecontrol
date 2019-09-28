require 'sinatra/base'
require 'thin'
require 'yaml'

# The TCP backend of the API
class BoilerThinBackend < ::Thin::Backends::TcpServer
  def initialize(host, port, options)
    super(host, port)
    @ssl = true
    @ssl_options = options
  end
end

# Setup the webserver for the rest interface

$BoilerRestapi = Sinatra.new do
  configure do
    set :environment, :production
    set :bind, $config[:rest_serverip]
    set :port, $config[:rest_serverport]
    set :server, 'thin'
    class << settings
      def server_settings
        {
          backend:           BoilerThinBackend,
          private_key_file:  $config[:rest_privatekey],
          cert_chain_file:   $config[:rest_cert_file],
          verify_peer:       false
        }
      end
    end
  end

  get '/config:itemname' do
    paramname = params['itemname'][1, 99].to_sym
    retval = ''.dup
    $config_mutex.synchronize do
      retval = $config[paramname]
    end
    return retval.to_s
  end

  get '/current:itemname' do
    case params['itemname']
    when ':living_temp'
      $boiler_control.living_thermostat.temp.round(2).to_s
    when ':upstairs_temp'
      $boiler_control.upstairs_thermostat.temp.round(2).to_s
    when ':basement_temp'
      $boiler_control.basement_thermostat.temp.round(2).to_s
    when ':external_temp'
      $boiler_control.living_floor_thermostat.temp.round(2).to_s
    end
  end

  put '/reload' do
    $boiler_control.reload
  end
end
