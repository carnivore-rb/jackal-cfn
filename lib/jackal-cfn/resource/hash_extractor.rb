require 'jackal-cfn'

module Jackal
  module Cfn
    class Resource
      # Extract value from hash
      #
      # Expected resource:
      #   {
      #     "Type": "Custom::HashExtractor",
      #     "Properties": {
      #       "Parameters": {
      #         "Key": "path.to.value.in.hash",
      #         "Value": Hash_or_JSON_string
      #       }
      #     }
      #   }
      class HashExtractor < Resource

        # Process message, send value back to CFN
        #
        # @param message [Carnivore::Message]
        def execute(message)
          payload = transform_parameters(unpack(message))
          debug "Processing payload: #{payload.inspect}"
          properties = transform_parameters(payload[:resource_properties])
          cfn_response = build_response(payload)
          parameters = transform_parameters(properties[:parameters])
          key = parameters[:key].split('.')
          value = parameters[:value]
          if(value.is_a?(String))
            value = MultiJson.load(value).to_smash
          end
          return_value = value.get(*key)
          if(return_value.is_a?(Enumerable))
            return_value = MultiJson.dump(return_value)
          end
          cfn_response['Data']['Payload'] = return_value
          respond_to_stack(cfn_response, payload[:response_url])
          completed(
            new_payload(
              config.fetch(:name, :hash_extractor),
              :cfn_resource => payload
            ),
            message
          )
        end

      end
    end
  end
end
