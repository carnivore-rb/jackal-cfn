require 'jackal-cfn'

module Jackal
  module Cfn
    class Resource
      # Extract value from hash
      #
      # Expected resource properties:
      #   {
      #     "Properties": {
      #       "Parameters": {
      #         "Key": "path.to.value.in.hash",
      #         "Value": Hash_or_JSON_string
      #       }
      #     }
      #   }
      class HashExtractor < Resource

        # Validity of message
        #
        # @param message [Carnivore::Message]
        # @return [Truthy, Falsey]
        def valid?(message)
          super do |payload|
            payload.get(:resource_properties, :action) == 'hash_extractor'
          end
        end

        # Process message, send value back to CFN
        #
        # @param message [Carnivore::Message]
        def execute(message)
          failure_wrap do |payload|
            properties = transform_parameters('ResourceProperties')
            cfn_response = build_response(properties)
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
            respond_to_stack(cfn_response, properties)
            completed(
              new_payload(
                config.fetch(:name, :hash_extractor),
                :cfn_resource => payload
              )
            )
          end
        end

      end
    end
  end
end
