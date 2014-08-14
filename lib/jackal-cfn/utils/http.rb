require 'patron'
require 'jackal-cfn'

module Jackal
  module Cfn
    module Utils
      # Helper module for HTTP interactions
      module Http

        # Provide remote endpoint session for sending response
        #
        # @param host [String] end point host
        # @param scheme [String] end point scheme
        # @return [Patron::Session]
        def response_endpoint(host, scheme)
          session = Patron::Session.new
          session.timeout = config.fetch(:response_timeout, 20)
          session.connect_timeout = config.fetch(:connection_timeout, 10)
          session.base_url = "#{scheme}://#{host}"
          session.headers['User-Agent'] = "JackalCfn/#{Jackal::Cfn::VERSION.version}"
          session
        end
        alias_method :http_endpoint, :response_endpoint

      end

    end
  end
end
