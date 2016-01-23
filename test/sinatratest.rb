#!/usr/local/rvm/rubies/ruby-2.1.5/bin/ruby
require 'sinatra/base'
require 'thin'

class MyThinBackend < ::Thin::Backends::TcpServer
  def initialize(host, port, options)
    super(host, port)
    @ssl = true
    @ssl_options = options
  end
end

class BoilerRestapi < Sinatra::Application

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

end