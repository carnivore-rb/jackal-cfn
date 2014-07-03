require 'jackal-cfn'

module Jackal
  module Cfn
    # Callback for event types
    class Event < Jackal::Callback

      # Unpack message and create payload
      #
      # @param message [Carnivore::Message]
      # @return [Smash]
      def unpack(message)
        payload = super
        payload = format_event(payload.fetch('Body', 'Message', payload))
        payload[:origin_type] = message[:message].get('Body', 'Type')
        payload[:origin_subject] = message[:message].get('Body', 'Subject')
      end

      # Determine message validity
      #
      # @param message [Carnivore::Message]
      # @return [TrueClass, FalseClass]
      def valid?(message)
        super do |payload|
          result = payload[:origin_type] == 'Notification' &&
            payload[:origin_subject].downcase.include?('cloudformation notification')
          if(result && block_given?)
            yield payload
          else
            result
          end
        end
      end

      # Format payload into proper event structure
      #
      # @param evt [Hash]
      # @return [Smash]
      def format_event(evt)
        parts = evt.split("\n").map do |entry|
          chunks = entry.split('=')
          key = parts.unshift.strip
          value = parts.join.strip.sub(/^'/, '').sub(/'$/, '').strip
          [key, value]
        end
        event = Smash[parts]
        unless(event['ResourceProperties'].to_s.empty?)
          begin
            event['ResourceProperties'] = MultiJson.load(event['ResourceProperties'])
          rescue MultiJson::LoadError => e
            error "Failed to load `ResourceProperties`: #{e.class} - #{e}"
            debug "#{e.class}: #{e}\n#{e.backtrace.join("\n")}"
          end
        else
          event['ResourceProperties'] = {}
        end
        Smash.new(Carnivore::Utils.symbolize_hash(event))
      end

      # Generate payload and drop
      #
      # @param message [Carnivore::Message]
      def execute(message)
        failure_wrap do |payload|
          job_completed(
            new_payload(
              config[:name],
              :cfn_event => payload
            )
          )
        end
      end

    end
  end
end
