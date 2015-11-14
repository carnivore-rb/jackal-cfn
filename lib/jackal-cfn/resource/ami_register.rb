require 'jackal-cfn'

module Jackal
  module Cfn
    # Register an AMI from an EC2 resource
    #
    # Expected resource:
    #   {
    #     "Type": "Custom::AmiRegister",
    #     "Properties": {
    #       "Parameters": {
    #         "Name": String,
    #         "InstanceId": String,
    #         "Description": String,
    #         "NoReboot": Boolean,
    #         "BlockDeviceMappings": Array,
    #         "HaltInstance": Boolean,
    #         "Region": String,
    #         "Register" : {
    #           REGISTER_OPTIONS
    #         }
    #       }
    #     }
    #   }
    #
    # Response Hash:
    #   {
    #     "AmiId": String
    #   }
    #
    # Required configuration:
    #   {
    #     "config": {
    #       "ami": {
    #         "credentials": {
    #           "compute": {
    #             FOG_CREDENTIALS
    #           }
    #         }
    #       }
    #     }
    #   }
    class AmiRegister < Jackal::Cfn::Resource

      PHYSICAL_ID_JOINER = '__-__'

      # Ensure fog library is loaded
      def setup(*_)
        require 'fog'
      end

      # Process message, send value back to CFN
      #
      # @param message [Carnivore::Message]
      def execute(message)
        failure_wrap(message) do |payload|
          cfn_resource = rekey_hash(payload.get(:data, :cfn_resource))
          properties = rekey_hash(cfn_resource[:resource_properties])
          parameters = rekey_hash(properties[:parameters])
          cfn_response = build_response(cfn_resource)
          poll_for_available = false
          case cfn_resource[:request_type].to_sym
          when :create
            generate_ami(cfn_response, parameters)
            poll_for_available = true
          when :update
            destroy_ami(cfn_response, cfn_resource, parameters)
            unless(cfn_response['Status'] == 'FAILED')
              generate_ami(cfn_response, parameters)
              poll_for_available = true
            end
          when :delete
            destroy_ami(cfn_response, cfn_resource, parameters)
          else
            error "Unknown request type received: #{cfn_resource[:request_type].inspect}"
            cfn_response['Status'] = 'FAILED'
            cfn_response['Reason'] = 'Unknown request type received'
          end
          if(poll_for_available && cfn_response['Status'] != 'FAILED')
            result = poll_ami_available(message, parameters[:region], cfn_response['Data']['AmiId'])
            if(result != 'available')
              cfn_response['Status'] = 'FAILED'
              cfn_response['Reason'] = "Registered AMI resulted in FAILED state #{cfn_response['Data']['AmiId']}"
            else
              if(parameters[:halt_instance].to_s == 'true')
                halt_ec2_instance(parameters)
              end
            end
          end
          respond_to_stack(cfn_response, cfn_resource[:response_url])
          job_completed(:jackal_cfn, payload, message)
        end
      end

      # Poll the status of the AMI being generated and return the
      # final state once no longer "pending"
      #
      # @param message [Carnivore::Message]
      # @param region [String]
      # @param ami_id [String]
      # @return [String] state of image (available/failed)
      def poll_ami_available(message, region, ami_id)
        available = false
        pause_interval = config.fetch(:ami_register_interval, 5).to_i
        if(ami_id)
          until(available)
            debug "Pausing for AMI to become available: #{ami_id} (wait time: #{pause_interval})"
            message.touch!
            sleep(pause_interval)
            result = compute_api(region).describe_images(
              'ImageId' => [ami_id]
            )
            result = result.body['imagesSet'].first
            if(result['imageState'] != 'pending')
              available = result['imageState']
            else
              debug "AMI is still in pending state: #{ami_id}"
            end
          end
          available
        else
          raise ArgumentError.new 'No AMI ID was provided to poll for available state!'
        end
      end

      # Halt an EC2 instance
      #
      # @param instance_id [String] EC2 instance ID
      # @return [TrueClass, FalseClass]
      def halt_ec2_instance(parameters)
        begin
          compute_api(parameters[:region]).stop_instances([parameters[:instance_id]])
          info "Halted EC2 instance: #{parameters[:instance_id]}"
          true
        rescue => e
          warn "Failed to halt requested EC2 instance: #{parameters[:instance_id]} (#{e.class}: #{e.message})"
          false
        end
      end

      # Create new AMI using provided EC2 instance
      #
      # @param response [Hash] cfn response
      # @param parameters [Hash] resource parameters
      # @return [Hash] updated response hash
      def generate_ami(response, parameters)
        begin
          result = compute_api(parameters[:region]).create_image(
            parameters[:instance_id],
            parameters[:name],
            parameters[:description],
            parameters[:no_reboot],
            :block_device_mappings => parameters.fetch(:block_device_mappings, [])
          )
          info "New AMI created: #{result.body['imageId']}"
          if(parameters[:register])
            register_parameters = Hash[
              parameters[:register].map do |k,v|
                [Bogo::Utility.camel(k), v]
              end
            ]
            image_info = compute_api(parameters[:region]).describe_images('ImageId' => result.body['imageId']).body['imagesSet'].first
            register_result = compute_api(parameters[:region]).register_image(
              image_info['rootDeviceName'],
              image_info['blockDeviceMapping'],
              {
                'Architecture' => image_info['architecture'],
                'VirtualziationType' => image_info['virtualizationType'],
              }.merge(register_parameters)
            )
            unless(result.body['imageId'] == register_result.body['imageId'])
              info "New AMI registered: #{register_result.body['imageId']} - Destroying created image: #{result.body['imageId']}"
              compute_api(parameters[:region]).deregister_image(result.body['imageId'])
            end
            result = register_result
          end
          response['Data']['AmiId'] = result.body['imageId']
          response['PhysicalResourceId'] = [
            physical_resource_id,
            result.body['imageId']
          ].join(PHYSICAL_ID_JOINER)
        rescue ::Fog::Compute::AWS::Error => e
          warn "Failed to create AMI: #{e.class}: #{e.message}"
          response['Reason'] = "AMI Creation failed: #{e.message}"
          response['Status'] = 'FAILED'
        rescue => e
          error "Unexpected error creating AMI: #{e.class}: #{e.message}"
          response['Status'] = 'FAILED'
          response['Reason'] = "Unexpected error: #{e.message}"
          response['PhysicalResourceId'] = [
            response['PhysicalResourceId'],
            parameters[:ami_id]
          ].join(PHYSICAL_ID_JOINER)
        end
        response
      end

      # Destroy the AMI referenced by the resource
      #
      # @param response [Hash] cfn response
      # @param payload [Hash] message payload
      # @param parameters [Hash] resource parameters
      # @return [TrueClass]
      def destroy_ami(response, payload, parameters)
        ami_id = payload[:physical_resource_id].split(PHYSICAL_ID_JOINER).last
        begin
          info "Destroying registered AMI: #{ami_id}"
          compute_api(parameters[:region]).deregister_image(ami_id)
        rescue ::Fog::Compute::AWS::Error => e
          warn "Failed to remove AMI: #{e.class}: #{e}"
          response['Reason'] = "Failed to remove AMI resource: #{e}. Ignoring."
        rescue => e
          error "Unexpected error removing AMI: #{e.class}: #{e}"
          response['Status'] = 'FAILED'
          response['Reason'] = e.message
        end
        true
      end

      # Build new compute api connection
      #
      # @param region [String] AWS region ami exists
      # @return [Fog::Compute]
      def compute_api(region)
        ::Fog::Compute.new(
          {:provider => :aws}.merge(
            config.get(:ami, :credentials, :compute).merge(
              :region => region
            )
          )
        )
      end

    end
  end
end
