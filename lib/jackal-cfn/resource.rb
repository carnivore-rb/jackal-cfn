require 'jackal-cfn'

module Jackal
  module Cfn
    # Callback for resource types
    class Resource < Jackal::Callback

      # Validity method for subclasses
      module InheritedValidity

        # Determine message validity
        #
        # @param message [Carnivore::Message]
        # @return [TrueClass, FalseClass]
        def valid?(message)
          super do |payload|
            data = payload.fetch(:data, :cfn_resource, Smash.new)
            resource_type = data[:resource_type].to_s.split('::').last
            result = data[:origin_type] == 'Notification' &&
              data[:origin_subject].to_s.downcase.include?('cloudformation custom resource') &&
              self.class.to_s.split('::').last == resource_type
            if(result && block_given?)
              yield payload
            else
              result
            end
          end
        end

      end

      include Jackal::Cfn::Utils
      include Jackal::Cfn::Utils::Http

      VALID_RESOURCE_STATUS = ['SUCCESS', 'FAILED']

      # Update validity checks in subclasses
      #
      # @param klass [Class]
      def self.inherited(klass)
        klass.class_eval do
          include InheritedValidity
        end
      end

      # Determine message validity
      #
      # @param message [Carnivore::Message]
      # @return [TrueClass, FalseClass]
      def valid?(message)
        super do |payload|
          if(block_given?)
            yield payload
          else
            payload[:origin_type] == 'Notification' &&
              payload[:origin_subject].to_s.downcase.include?('cloudformation custom resource')
          end
        end
      end

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
        "#{self.class.name.split('::').last}-#{Celluloid.uuid}"
      end

      # Generate response hash
      #
      # @param cfn_resource [Hash]
      # @option cfn_resource [String] :logical_resource_id
      # @option cfn_resource [String] :physical_resource_id
      # @option cfn_resource [String] :stack_id
      # @option cfn_resource [String] :request_id
      # @return [Hash] default response content
      def build_response(cfn_resource)
        Smash.new(
          'LogicalResourceId' => cfn_resource[:logical_resource_id],
          'PhysicalResourceId' => cfn_resource.fetch(:physical_resource_id, physical_resource_id),
          'StackId' => cfn_resource[:stack_id],
          'RequestId' => cfn_resource[:request_id],
          'Status' => 'SUCCESS',
          'Data' => Smash.new
        )
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
        payload = super
        if(self.is_a?(Jackal::Cfn::Resource))
          begin
            if(payload['Body'] && payload['Body']['Message'])
              payload = MultiJson.load(payload.get('Body', 'Message')).to_smash
              payload = transform_parameters(payload)
              payload[:origin_type] = message[:message].get('Body', 'Type')
              payload[:origin_subject] = message[:message].get('Body', 'Subject')
              payload[:request_type] = snakecase(payload[:request_type])
              payload
            else
              payload.to_smash.fetch('Attributes', 'Body', payload.to_smash.fetch('Body', payload.to_smash))
            end
          rescue MultiJson::ParseError
            # Not our expected format so return empty payload
            Smash.new
          end
        else
          payload.to_smash.fetch('Attributes', 'Body', payload.to_smash.fetch('Body', payload.to_smash))
        end
      end

      # Generate payload and drop
      #
      # @param message [Carnivore::Message]
      def execute(message)
        data_payload = unpack(message)
        payload = new_payload(
          config.fetch(:name, :jackal_cfn),
          :cfn_resource => data_payload
        )
        if(config[:reprocess])
          Carnivore::Supervisor.supervisor[destination(:input, payload)].transmit(payload)
          message.confirm!
        else
          completed(payload, message)
        end
      end

      # Custom wrap to send resource failure
      #
      # @param message [Carnivore::Message]
      def failure_wrap(message)
        begin
          payload = unpack(message)
          yield payload
        rescue => e
          error "Unexpected error encountered processing custom resource - #{e.class}: #{e.message}"
          debug "#{e.class}: #{e}\n#{e.backtrace.join("\n")}"
          cfn_resource = payload.get(:data, :cfn_resource)
          cfn_response = build_response(cfn_resource)
          cfn_response['Status'] = 'FAILED'
          cfn_response['Reason'] = "Unexpected error encountered [#{e.message}]"
          respond_to_stack(cfn_response, cfn_resource[:response_url])
          message.confirm!
        end
      end

    end
  end
end
