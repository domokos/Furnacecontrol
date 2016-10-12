require "sinatra/base"
require "thin"
require "yaml"

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
    set :bind, '192.168.130.4'
    set :port, 9999
    set :server, "thin"
    class << settings
      def server_settings
        {
          :backend          => BoilerThinBackend,
          :private_key_file => "/etc/pki/tls/private/hera.szilva.key",
          :cert_chain_file  => "/etc/pki/tls/certs/hera.szilva.crt",
          :verify_peer      => false
        }
      end
    end
  end

  get '/config:itemname' do
    paramname = params['itemname'][1,99].to_sym
    retval = ""
    $config_mutex.synchronize do
      retval = $config[paramname]
    end
    return retval.to_s
  end

  get '/current:itemname' do
    case params['itemname']
    when ":living_temp"
      $boiler_control.living_thermostat.temp.round(2).to_s
    when ":upstairs_temp"
      $boiler_control.upstairs_thermostat.temp.round(2).to_s
    when ":basement_temp"
      $boiler_control.basement_thermostat.temp.round(2).to_s
    when ":external_temp"
      $boiler_control.living_floor_thermostat.temp.round(2).to_s
    end
  end

  put '/reload' do
    $boiler_control.reload
  end

end