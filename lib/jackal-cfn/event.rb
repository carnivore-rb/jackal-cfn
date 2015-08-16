require 'jackal-cfn'

module Jackal
  module Cfn
    # Callback for event types
    class Event < Jackal::Callback

      module InheritedValidity
        # Determine message validity
        #
        # @param message [Carnivore::Message]
        # @return [TrueClass, FalseClass]
        def valid?(message)
          super do |payload|
            data = payload.fetch(:data, :cfn_event, Smash.new)
            result = data[:origin_type] == 'Notification' &&
              data[:origin_subject].to_s.downcase.include?('cloudformation notification')
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

      # Update validity checks in subclasses
      #
      # @param klass [Class]
      def self.inherited(klass)
        klass.class_eval do
          include InheritedValidity
        end
      end

      # Unpack message and create payload
      #
      # @param message [Carnivore::Message]
      # @return [Smash]
      def unpack(message)
        payload = super
        if(self.class == Jackal::Cfn::Event)
          begin
            unless(payload.get(:data, :cfn_event))
              payload = format_event(payload.fetch('Body', 'Message', payload))
              payload[:origin_type] = message[:message].get('Body', 'Type')
              payload[:origin_subject] = message[:message].get('Body', 'Subject')
            end
            payload
          rescue
            Smash.new
          end
        else
          payload.to_smash.fetch('Body', payload.to_smash)
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
              payload[:origin_subject].downcase.include?('cloudformation notification')
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
          key = chunks.shift.strip
          value = chunks.join.strip.sub(/^'/, '').sub(/'$/, '').strip
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
        data_payload = unpack(message)
        payload = new_payload(
          config[:name],
          :cfn_event => data_payload
        )
        if(config[:reprocess])
          debug "Reprocessing payload through current source (#{destination(:input, payload)})"
          Carnivore::Supervisor.supervisor[destination(:input, payload)].transmit(payload)
          message.confirm!
        else
          job_completed(:jackal_cfn, payload, message)
        end
      end

    end
  end
end
