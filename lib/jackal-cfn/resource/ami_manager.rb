require 'jackal-cfn'

module Jackal
  module Cfn
    class Resource
      # Manage AMI Resources
      #
      # Expected resource:
      #   {
      #     "Type": "Custom::AmiManager",
      #     "Properties": {
      #       "Parameters": {
      #         "InstanceId": "",
      #         "AmiId": "",
      #         "Action": "",
      #         "Region": ""
      #       }
      #     }
      #   }
      #
      # Required configuration:
      #   {
      #     "config": {
      #       "credentials": {
      #         "compute": {
      #           FOG_CREDENTIALS
      #         }
      #       }
      #     }
      #   }
      class AmiManager < Resource

        PHYSICAL_ID_JOINER = '__-__'

        # Process message, send value back to CFN
        #
        # @param message [Carnivore::Message]
        def execute(message)
          failure_wrap do |payload|
            cfn_resource = rekey_hash(payload.get(:data, :cfn_resource))
            properties = rekey_hash(cfn_resource[:resource_properties])
            parameters = rekey_hash(properties[:parameters])
            cfn_response = build_response(cfn_resource)
            case cfn_resource[:request_type]
            when :create
              ami_response_update(cfn_response, parameters)
            when :delete
              destroy_ami(cfn_response, cfn_resource, parameters)
            when :update
            else
              error "Unknown request type received: #{cfn_resource[:request_type].inspect}"
              response['Status'] = 'FAILED'
              response['Reason'] = 'Unknown request type received'
            end
            respond_to_stack(response, cfn_resource[:response_url])
            completed(payload, message)
          end
        end

        # Update the physical resource id to include the ami id
        #
        # @param response [Hash] cfn response
        # @param parameters [Hash] resource parameters
        # @return [Hash] updated response hash
        def ami_response_update(response, parameters)
          response['PhysicalResourceId'] = [
            response['PhysicalResourceId'],
            parameters[:ami_id]
          ].join(PHYSICAL_ID_JOINER)
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
            compute_api(parameters[:region]).deregister_image(ami_id)
          rescue Fog::Compute::AWS::Error => e
            warn "Non-fatal error encountered on AMI removal: #{e.class}: #{e}"
            response['Reason'] = e.message
          rescue => e
            error "Failed to remove AMI: #{e.class}: #{e}"
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
          Fog::Compute.new(
            {:provider => :aws}.merge(
              config.fetch(
                :credentials, :compute, {}
              ).merge(:region => region)
            )
          )
        end

      end
    end
  end
end
