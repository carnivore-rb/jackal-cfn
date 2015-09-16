require 'jackal-cfn'

module Jackal
  module Cfn
    module Utils
      # Helper module for loading Fog APIs
      module Fog

        include Utils

        # Provide API for given type
        #
        # @param type [Symbol] Fog API (compute, orchestration, etc)
        # @return [Fog::Service]
        # @note extracts credentials from confg at :api -> [type | :default]
        def api_for(type)
          klass = ::Fog.constants.detect do |const|
            snakecase(const).to_s == type.to_s
          end
          if(klass)
            credentials = config.fetch(
              :api, type, config.get(
                :api, :default
              )
            )
            if(credentials)
              key = credentials.to_a.flatten.push(klass).sort.hash
              Thread.current[:cfn_apis] ||= Smash.new
              unless(Thread.current[:cfn_apis][key])
                Thread.current[:cfn_apis][key] = ::Fog.const_get(klass).new(credentials)
              end
              Thread.current[:cfn_apis][key]
            else
              ArgumentError.new 'No credentials provided in configuration!'
            end
          else
            raise TypeError.new "Unknown API type requested (#{type})"
          end
        end

        # Assume the role for the API connection
        #
        # @param api [Fog::Service]
        # @param role [String] name of role to assume
        # @return [Fog::Service] assumed service
        # @note this is AWS specific
        def api_assume_for(api, role)
          Thread.current[:cfn_assume_apis] ||= Smash.new
          key = api.to_yaml_properties.group_by do |item|
            item.to_s.split('_').first
          end.values.sort_by(&:size).last.map do |var|
            [var, api.instance_variable_get(var)]
          end.flatten.compact.map(&:to_s).push(api.service_name).sort.hash
          if(Thread.current[:cfn_assume_apis].get(key, :expires).to_i < Time.now.to_i + 5)
            sts = ::Fog::AWS::STS.new(
              config.fetch(
                :api, :sts, config.get(
                  :api, :default
                )
              )
            )
            result = sts.assume_role("jackal-cfn-#{Carnivore.uuid}", role).body
            Thread.current[:cfn_assume_apis][key] = Smash.new(
              :expires => Time.parse(result['Expiration']).to_i,
              :api => api.class.new(
                :aws_access_key_id => result['AccessKeyId'],
                :aws_secret_access_key => result['SecretAccessKey'],
                :aws_session_token => result['SessionToken']
              )
            )
          end
          Thread.current[:cfn_assume_apis].get(key, :api)
        end

      end
    end
  end
end
