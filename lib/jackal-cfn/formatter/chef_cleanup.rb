require 'jackal'

module Jackal
  module Cfn
    module Formatter

      # Add cleanup information for chef instances
      class ChefCleanup < Jackal::Formatter

        # Source service
        SOURCE = :cfn
        # Destination service
        DESTINATION = :commander

        # Format payload to enable knife scrubbing via
        # commander
        #
        # @param payload [Smash]
        def format(payload)
          event = payload.get(:data, :cfn_event)
          if(valid_event?(event))
            stack_id = payload.get(:data, :cfn_event, :stack_id)
            if(stack_id)
              debug "Found stack ID information. Setting commander scrub commands. (Stack ID: #{stack_id})"
              actions = payload.fetch(:data, :commander, :actions, [])
              actions << Smash.new(
                :name => app_config.fetch(:cfn, :formatter, :chef_cleanup_command, :chef_cleanup),
                :arguments => stack_id
              )
              payload.set(:data, :commander, :actions, actions)
            end
          end
        end

        # Determine validity of event
        #
        # @param event [Smash]
        # @return [Truthy, Falsey]
        def valid_event?(event)
          event[:resource_status] == 'DELETE_COMPLETE' &&
            event[:resource_type] == app_config.fetch(:cfn, :formatter, :stack_resource_type, 'AWS::CloudFormation::Stack')
        end

      end

    end
  end
end
