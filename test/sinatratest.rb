#!/usr/local/rvm/rubies/ruby-2.1.5/bin/ruby
require 'sinatra/base'
require 'thin'
require 'yaml'

class MyThinBackend < ::Thin::Backends::TcpServer
  def initialize(host, port, options)
    super(host, port)
    @ssl = true
    @ssl_options = options
  end
end

$BoilerRestapi = Sinatra.new do

  configure do
    set :environment, :production
    set :bind, '192.168.130.4'
    set :port, 4567
    set :server, "thin"
    class << settings
      def server_settings
        {
          :backend          => MyThinBackend,
          :private_key_file => "/etc/pki/tls/private/hera.szilva.key",
          :cert_chain_file  => "/etc/pki/tls/certs/hera.szilva.crt",
          :verify_peer      => false
        }
      end
    end
  end

  get '/' do
    "Hello, SSL."
  end

  get '/temperatures' do
    "<upstairs>21.2</upstairs>
  <basement>25.12</downstairs>"
  end

  get '/kuty' do
    puts $alma.szorzott(2)
    $kutyumuyu.to_yaml
  end

  get '/config:itemname' do
    $config = {}
    $config[:target_living_temp] = 150

    puts params['itemname']
    puts params['itemname'].to_sym

    $config[params['itemname']]
  end

end
