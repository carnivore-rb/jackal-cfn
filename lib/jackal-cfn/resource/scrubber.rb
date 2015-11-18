require 'jackal-cfn'

module Jackal
  module Cfn
    class Scrubber < Jackal::Cfn::Resource

      def valid?(message)
        payload = unpack(message)
        payload.get(:data, :cfn_resource)
      end

      # Scrub resource
      #
      # @param message [Carnivore::Message]
      def execute(message)
        failure_wrap(message) do |payload|
          cfn_resource = rekey_hash(payload.get(:data, :cfn_resource))
          properties = rekey_hash(cfn_resource[:resource_properties])
          parameters = rekey_hash(properties[:parameters])
          cfn_response = build_response(cfn_resource)
          respond_to_stack(cfn_response, cfn_resource[:response_url])
          job_completed(:jackal_cfn, payload, message)
        end
      end

    end
  end
end
