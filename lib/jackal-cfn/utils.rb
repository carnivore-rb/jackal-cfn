require 'jackal-cfn'

module Jackal
  module Cfn
    module Utils

      autoload :Fog, 'jackal-cfn/utils/fog'
      autoload :Http, 'jackal-cfn/utils/http'

      # Snake case top level keys in hash
      #
      # @param params [Hash]
      # @return [Hash] new hash with snake cased toplevel keys
      def transform_parameters(params)
        Smash.new.tap do |new_hash|
          (params || []).each do |key, value|
            new_hash[snakecase(key)] = value
          end
        end
      end
      alias_method :rekey_hash, :transform_parameters

      # Snake case string
      #
      # @param v [String]
      # @return [Symbol]
      def snakecase(v)
        Bogo::Utility.snake(v)
      end

    end
  end
end
