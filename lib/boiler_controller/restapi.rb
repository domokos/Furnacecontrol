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
    set :port, 4567
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

  get '/config' do
    retval = ""
    $config_mutex.synchronize do
      retval = $config.to_yaml
    end
    return retval
  end
  
  
  
end