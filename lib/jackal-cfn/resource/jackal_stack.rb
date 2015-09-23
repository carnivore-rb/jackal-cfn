require 'jackal-cfn'

module Jackal
  module Cfn
    # Manage AMI Resources
    #
    # Expected resource:
    #   {
    #     "Type": "Custom::JackalStack",
    #     "Properties": {
    #       "Parameters": {
    #         STACK_PARAMETERS
    #       },
    #       "Location": LOCATION,
    #       "TemplateURL": "URL"
    #     }
    #   }
    #
    # Required configuration:
    #   {
    #     "config": {
    #       "jackal_stack": {
    #         "credentials": {
    #           "storage": {
    #             AWS_CREDENTIALS
    #           },
    #           LOCATION: {
    #             "provider": "NAME",
    #             MIAMSA_CREDENTIALS
    #           }
    #         }
    #       }
    #     }
    #   }
    class JackalStack < Jackal::Cfn::Resource

      LOCATION_JOINER = '__~__'

      # Load miasma for stack building
      def setup(*_)
        require 'miasma'
      end

      # Perform requested stack action
      #
      # @param message [Carnivore::Message]
      def execute(message)
        failure_wrap(message) do |payload|
          cfn_resource = rekey_hash(payload.get(:data, :cfn_resource))
          properties = rekey_hash(cfn_resource[:resource_properties])
          parameters = rekey_hash(properties[:parameters])
          cfn_response = build_response(cfn_resource)
          case cfn_resource[:request_type].to_sym
          when :create
            create_stack(cfn_response, cfn_resource, properties, parameters, message)
          when :update
            update_stack(cfn_response, cfn_resource, properties, parameters, message)
          when :delete
            destroy_stack(cfn_response, cfn_resource, message)
          else
            error "Unknown request type received: #{cfn_resource[:request_type].inspect}"
            cfn_response['Status'] = 'FAILED'
            cfn_response['Reason'] = 'Unknown request type received'
          end
          respond_to_stack(cfn_response, cfn_resource[:response_url])
          job_completed(:jackal_cfn, payload, message)
        end
      end

      # Build API connection to base template storage bucket
      #
      # @param bucket_region [String] location of bucket
      # @return [Miasma::Models::Storage]
      def storage_api(bucket_region)
        Miasma.api(
          :type => :storage,
          :provider => :aws,
          :credentials => config.get(:jackal_stack, :credentials, :storage).merge(
            :aws_bucket_region => bucket_region
          )
        )
      end

      # Build orchestration API connection for provided location
      #
      # @param location [String, Symbol]
      # @return [Miasma::Models::Orchestration]
      def remote_api(location)
        l_config = config.get(:jackal_stack, :credentials, location)
        if(l_config)
          Miasma.api(
            :type => :orchestration,
            :provider => l_config[:provider],
            :credentials => l_config
          )
        else
          raise ArgumentError.new "Unknown target location provided `#{location}`!"
        end
      end

      # Fetch a template from a storage bucket
      #
      # @param endpoint [String] URL to template
      # @return [Hash] loaded template data
      def fetch_template(endpoint)
        url = URI.parse(endpoint)
        region = url.host.split('.').first.split('-', 2).last
        if(region == 's3')
          region = 'us-east-1'
        end
        bucket, path = url.path.sub('/', '').split('/', 2)
        MultiJson.load(
          storage_api(region).buckets.get(
            bucket.sub('/', '')
          ).files.get(path).body.read
        )
      end

      # Generate the remote stack name via the resource information
      #
      # @param resource [Hash]
      # @return [String]
      def generate_stack_name(resource)
        [
          'JackalStack',
          resource[:logical_resource_id],
          resource[:stack_id].split('/').last
        ].join('-')
      end

      # Create a new stack and update the response values
      #
      # @param response [Hash] response data of action
      # @param resource [Hash] request resource
      # @param properties [Hash] properties of request resource
      # @param parameters [Hash] parmeters provided via properties
      # @param message [Carnivore::Message] original message
      # @return [TrueClass, FalseClass]
      def create_stack(response, resource, properties, parameters, message)
        stack = remote_api(properties[:location]).stacks.build(
          :name => generate_stack_name(resource),
          :template => properties.fetch(:stack, fetch_template(properties[:template_url])),
          :parameters => Hash[parameters.map{|k,v| [Bogo::Utility.camel(k), v] }]
        )
        stack.save
        until(stack.state.to_s.end_with?('complete'))
          message.touch!
          debug "Waiting for created stack to reach completion..."
          sleep 5
          stack.reload
        end
        if(stack.state.to_s.end_with?('complete') || stack.state.to_s.end_with?('failed'))
          stack.outputs.each do |output|
            response['Data']["Outputs.#{output.key}"] = output.value
          end
          response['PhysicalResourceId'] = [
            properties[:location],
            stack.id
          ].join(LOCATION_JOINER)
          true
        else
          response['Status'] = 'FAILED'
          response['Reason'] = 'Stack creation failed!'
          stack.destroy
          false
        end
      end

      # Update an existing stack and update the response values
      #
      # @param response [Hash] response data of action
      # @param resource [Hash] request resource
      # @param properties [Hash] properties of request resource
      # @param parameters [Hash] parmeters provided via properties
      # @param message [Carnivore::Message] original message
      # @return [TrueClass, FalseClass]
      def update_stack(response, resource, properties, parameters, message)
        c_location, stack_id = resource[:physical_resource_id].split('-', 2)
        if(c_location != properties[:location])
          warn "Stack resource has changed location! #{c_location} -> #{properties[:location]}"
          warn "Starting destruction of existing resource: #{stack_id}"
          if(destroy_stack(response, resource, message))
            info "Destruction of stack `#{stack_id}` complete. Creating replacement stack."
            create_stack(response, resource, properties, parameters, message)
          else
            error "Failed to destroy existing stack for replacement `#{stack_id}`"
          end
        else
          stack = remote_api(c_location).stacks.get(stack_id)
          if(stack)
            info "Stack resource update on: #{stack_id}"
            stack.template = fetch_template(properties['TemplateURL'])
            stack.parameters = Hash[parameters.map{|k,v| [Bogo::Utility.camel(k), v] }]
            stack.save
            until(stack.state.to_s.end_with?('complete') || stack.state.to_s.end_with?('failed'))
              debug "Waiting for created stack to reach completion..."
              sleep 5
              stack.reload
            end
            if(stack.state.to_s.end_with?('complete'))
              stack.outputs.each do |output|
                response['Data']["Outputs.#{output.key}"] = output.value
              end
              response['PhysicalResourceId'] = stack.id
            else
              response['Status'] = 'FAILED'
              response['Reason'] = 'Stack update failed!'
            end
          else
            response['Status'] = 'FAILED'
            response['Reason'] = "No stack was found matching request: #{stack_id}"
          end
        end
      end

      # Destroy the stack
      #
      # @param response [Hash] response data of action
      # @param resource [Hash] request resource
      # @param message [Carnivore::Message] original message
      def destroy_stack(response, resource, message)
        stack = request_destroy(resource[:physical_resource_id])
        unless(stack)
          properties = rekey_hash(resource[:resource_properties])
          stack = request_destroy(
            [
              properties[:location],
              generate_stack_name(resource)
            ].join(LOCATION_JOINER)
          )
        end
        if(stack)
          until(stack.state.nil? || stack.state.to_s.end_with?('complete') || stack.state.to_s.end_with?('failed'))
            info "Waiting for stack destruction (#{stack.name})..."
            message.touch!
            sleep 5
            stack.reload
          end
          if(stack.state.to_s.end_with?('failed'))
            response['Status'] = 'FAILED'
            response['Reason'] = 'Failed to delete remote stack!'
          end
        end
      end

      # Send a stack delete request
      #
      # @param stack_resource_id [String] physical resource ID
      # @return [Miasma::Models::Orchestration::Stack, FalseClass]
      def request_destroy(stack_resource_id)
        location, stack_id = stack_resource_id.split(LOCATION_JOINER, 2)
        if(stack_id)
          begin
            info "Sending stack destruction request to: #{stack_id} in: #{location}"
            stack = remote_api(location).stacks.get(stack_id)
            stack.destroy
            stack
          rescue => e
            error "Stack destruction request failed! #{e.class}: #{e.message}"
            false
          end
        else
          warn "No stack ID registered in resource. Skipping destroy: #{stack_resource_id}"
          false
        end
      end

    end
  end
end
