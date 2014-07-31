require 'jackal-cfn'

module Jackal
  module Cfn
    # Callback for resource types
    class Resource < Jackal::Callback

      include Jackal::Cfn::Utils

      VALID_RESOURCE_STATUS = ['SUCCESS', 'FAILED']

      autoload :HashExtractor, 'jackal-cfn/resource/hash_extractor'
      autoload :AmiManager, 'jackal-cfn/resource/ami_manager'

      # Setup the dependency requirements for the callback
      def setup(*_)
        require 'patron'
      end

      # Physical ID of the resource created
      #
      # @return [String]
      # @note this should be overridden in subclasses when actual
      #   resources are being created
      def physical_resource_id
        "#{self.class.name}-#{Celluloid.uuid}"
      end

      # Generate response hash
      #
      # @param payload [Hash]
      # @return [Hash] default response content
      def build_response(payload)
        args = transform_parameters(payload)
        Smash.new(
          'LogicalResourceId' => args[:logical_resource_id],
          'PhysicalResourceId' => args.fetch(:physical_resource_id, physical_resource_id),
          'StackId' => args[:stack_id],
          'RequestId' => args[:request_id],
          'Status' => 'SUCCESS',
          'Reason' => 'Not provided',
          'Data' => Smash.new
        )
      end

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

      # Send response to the waiting stack
      #
      # @param response [Hash]
      # @param response_url [String] response endpoint
      # @return [TrueClass, FalseClass]
      def respond_to_stack(response, response_url)
        unless(VALID_RESOURCE_STATUS.include?(response['Status']))
          raise ArgumentError.new "Invalid resource status provided. Got: #{response['Status']}. Allowed: #{VALID_RESOURCE_STATUS.join(', ')}"
        end
        if(response['Status'] == 'FAILED' && !response['Reason'])
          response['Reason'] = 'Unknown'
        end
        url = URI.parse(response_url)
        connection = response_endpoint(url.host, url.scheme)
        path = "#{url.path}?#{url.query}"
        debug "Custom resource response data: #{response.inspect}"
        complete = connection.put(path, JSON.dump(response))
        case complete.status
        when 200
          info "Custom resource response complete! (Sent to: #{url})"
          true
        when 403
          error "Custom resource response failed. Endpoint is forbidden (403): #{url}"
          false
        when 404
          error "Custom resource response failed. Endpoint is not found (404): #{url}"
          false
        else
          raise "Response failed. Received status: #{complete.status} endpoint: #{url}"
        end
      end

      # Unpack message and create payload
      #
      # @param message [Carnivore::Message]
      # @return [Smash]
      def unpack(message)
        begin
          payload = super
          payload = Smash.new(
            MultiJson.load(
              payload.fetch('Body', 'Message', payload)
            )
          )
          payload = transform_parameters(payload)
          payload[:origin_type] = message[:message].get('Body', 'Type')
          payload[:origin_subject] = message[:message].get('Body', 'Subject')
          payload[:request_type] = snakecase(payload[:request_type])
          payload
        rescue MultiJson::ParseError
          # Not our expected format so return empty payload
          Smash.new
        end
      end

      # Determine message validity
      #
      # @param message [Carnivore::Message]
      # @return [TrueClass, FalseClass]
      def valid?(message)
        super do |payload|
          resource_type = payload[:resource_type].split('::').last
          result = payload[:origin_type] == 'Notification' &&
            payload[:origin_subject].downcase.include?('cloudformation custom resource') &&
            resource_type == self.class.name.split('::').last
          if(result && block_given?)
            yield payload
          else
            result
          end
        end
      end

      # Generate payload and drop
      #
      # @param message [Carnivore::Message]
      def execute(message)
        failure_wrap(message) do |payload|
          job_completed(
            new_payload(
              config[:name],
              :cfn_resource => payload
            )
          )
        end
      end

    end
  end
end
