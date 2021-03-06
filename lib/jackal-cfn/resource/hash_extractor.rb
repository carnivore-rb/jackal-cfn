require 'jackal-cfn'

module Jackal
  module Cfn
    # Extract value from hash
    #
    # Expected resource:
    #   {
    #     "Type": "Custom::HashExtractor",
    #     "Properties": {
    #       "Parameters": {
    #         "Key": "path.to.value.in.hash",
    #         "Value": JSON
    #       }
    #     }
    #   }
    class HashExtractor < Jackal::Cfn::Resource

      # Process message, send value back to CFN
      #
      # @param message [Carnivore::Message]
      def execute(message)
        failure_wrap(message) do |payload|
          cfn_resource = rekey_hash(payload.get(:data, :cfn_resource))
          properties = rekey_hash(cfn_resource[:resource_properties])
          parameters = rekey_hash(properties[:parameters])
          cfn_response = build_response(cfn_resource)
          key = parameters[:key].split('.')
          value = parameters[:value]
          unless(value.is_a?(String))
            unless(cfn_resource[:request_type].to_sym == :delete)
              raise TypeError.new("Expecting `String` value but received `#{value.class}`")
            end
            return_value = nil
          else
            value = MultiJson.load(value).to_smash
            return_value = value.get(*key)
            if(return_value.is_a?(Enumerable))
              return_value = MultiJson.dump(return_value)
            end
          end
          cfn_response['Data']['Payload'] = return_value
          respond_to_stack(cfn_response, cfn_resource[:response_url])
          job_completed(:jackal_cfn, payload, message)
        end
      end

    end
  end
end
