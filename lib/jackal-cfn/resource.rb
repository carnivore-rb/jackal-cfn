require 'jackal-cfn'

module Jackal
  module Cfn
    # Callback for resource types
    class Resource < Jackal::Callback

      VALID_RESOURCE_STATUS = ['SUCCESS', 'FAILED']

      autoload :HashExtractor, 'jackal-cfn/resource/hash_extractor'

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
      # @param resource_properties [Hash]
      # @return [Hash] default response content
      def build_response(resource_properties)
        properties = transform_parameters(resource_properties)
        Smash.new(
          'LogicalResourceId' => properties[:logical_resource_id],
          'PhysicalResourceId' => properties.fetch(:physical_resource_id, physical_resource_id),
          'StackId' => properties.fetch(:stack_id),
          'Status' => 'SUCCESS',
          'Reason' => nil,
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
        complete = connection.request(:put, path, {}, :data => JSON.dump(response))
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
        payload = super
        payload = Smash.new(
          MultiJson.load(
            payload.fetch('Body', 'Message', payload)
          )
        )
        payload[:origin_type] = message[:message].get('Body', 'Type')
        payload[:origin_subject] = message[:message].get('Body', 'Subject')
        payload
      end

      # Determine message validity
      #
      # @param message [Carnivore::Message]
      # @return [TrueClass, FalseClass]
      def valid?(message)
        super do |payload|
          result = payload[:origin_type] == 'Notification' &&
            payload[:origin_subject].downcase.include?('cloudformation custom resource')
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

      # Snake case top level keys in hash
      #
      # @param params [Hash]
      # @return [Hash] new hash with snake cased toplevel keys
      def transform_parameters(params)
        Smash.new.tap do |new_hash|
          params.each do |key, value|
            key = key.gsub(/(?<![A-Z])([A-Z])/, '_\1').sub(/^_/, '').downcase.to_sym
            new_hash[key] = value
          end
        end
      end

    end
  end
end
