require 'jackal-cfn'

module Jackal
  module Cfn
    # Execute arbitrary actions
    #
    # Expected resource:
    #   {
    #     "Type": "Custom::OrchestrationUnit",
    #     "Properties": {
    #       "Parameters": {
    #         "OnCreate": {
    #           "Exec": "SHELL_COMMAND",
    #           "ExecZip": "DOWNLOAD_URI",
    #           "RawResult": true,
    #           "Env": {
    #           },
    #           OnlyIf": "SHELL_COMMAND",
    #           NotIf": "SHELL_COMMAND"
    #         },
    #         "OnUpdate": {
    #           "Exec": "SHELL_COMMAND",
    #           "ExecZip": "DOWNLOAD_URI",
    #           "RawResult": true,
    #           "Env": {
    #           },
    #           },
    #           OnlyIf": "SHELL_COMMAND",
    #           NotIf": "SHELL_COMMAND"
    #         },
    #         "OnDelete": {
    #           "Exec": "SHELL_COMMAND",
    #           "ExecZip": "DOWNLOAD_URI",
    #           "RawResult": true,
    #           "Env": {
    #           },
    #           OnlyIf": "SHELL_COMMAND",
    #           NotIf": "SHELL_COMMAND"
    #         },
    #         "Exec": "SHELL_COMMAND",
    #         "ExecZip": "DOWNLOAD_URI",
    #         "Env": {
    #         },
    #         "RawResult": true,
    #         "OnlyIf": "SHELL_COMMAND",
    #         "NotIf": "SHELL_COMMAND"
    #       }
    #     }
    #   }
    #
    class OrchestrationUnit < Jackal::Cfn::Resource

      # Max result size
      MAX_RESULT_SIZE = 2048

      # Execute orchestration unit
      #
      # @param message [Carnivore::Message]
      def execute(message)
        failure_wrap(message) do |payload|
          cfn_resource = rekey_hash(payload.get(:data, :cfn_resource))
          properties = rekey_hash(cfn_resource[:resource_properties])
          parameters = rekey_hash(properties[:parameters])
          cfn_response = build_response(cfn_resource)
          unit = unit_for(cfn_resource[:request_type], parameters)
          if(unit_runnable?(unit))
            working_dir = create_working_directory(payload[:id])
            keepalive = every(10){ message.touch! }
            begin
              run_unit(unit, working_dir, cfn_response)
            ensure
              keepalive.cancel
            end
            FileUtils.rm_rf(working_dir)
          else
            debug "Received unit for #{message} is not runnable due to conditions! #{unit}"
          end
          respond_to_stack(cfn_response, cfn_resource[:response_url])
          job_completed(:jackal_cfn, payload, message)
        end
      end

      # Create a working directory for command execution
      #
      # @param uuid [String] unique identifier
      # @return [String] path
      def create_working_directory(uuid)
        dir_path = File.join(
          config.fetch(
            :working_directory,
            '/tmp/jackal-cfn'
          ),
          uuid
        )
        FileUtils.mkdir_p(dir_path)
        dir_path
      end

      # Determine if unit should be run based on conditional
      # fields
      #
      # @param unit [Hash]
      # @return [TrueClass, FalseClass]
      def unit_runnable?(unit)
        result = true
        conditionals = Smash[
          stdout = process_manager.create_io_tmp(Carnivore.uuid, 'stdout')
          stderr = process_manager.create_io_tmp(Carnivore.uuid, 'stderr')
          [:only_if, :not_if].map do |conditional_key|
            if(unit[conditional_key])
              debug "Executing conditional `#{conditional_key}`: #{unit[conditional_key]}"
              conditional_result = false
              process_manager.process(unit.hash, unit[conditional_key]) do |process|
                process.io.stdout = stdout
                process.io.stderr = stderr
                process.cwd = '/tmp'
                if(unit[:env])
                  debug "Custom environment defined: #{unit[:env]}"
                  process.environment.replace(unit[:env])
                end
                process.leader = true
                process.start
                begin
                  process.poll_for_exit(config.fetch(:max_execution_time, 60))
                  debug "Result of conditional `#{conditional_key}`: #{process.exit_code}"
                  stdout.rewind
                  stderr.rewind
                  debug "Result of conditional `#{conditional_key}` output STDOUT: #{stdout.read}"
                  debug "Result of conditional `#{conditional_key}` output STDERR: #{stderr.read}"
                  conditional_result = process.exit_code == 0
                rescue ChildProcess::TimeoutError
                  process.stop
                  conditional_result = false
                end
              end
              [conditional_key, conditional_result]
            end
          end.compact
        ]
        if(conditionals.key?(:not_if) && conditionals.key?(:only_if))
          result = !conditionals[:not_if] && conditionals[:only_if]
        elsif(conditionals.key?(:not_if))
          result = !conditionals.key?(:not_if)
        elsif(conditionals.key?(:only_if))
          result = conditionals[:only_if]
        end
        result
      end

      # Fetch compressed zip file from remote location and unpack into
      # provided working directory
      #
      # @param unit [Hash] orchestration unit
      # @param working_directory [String] local path to working directory
      # @return [Hash] unit
      # @note will automatically set `unit['Exec'] = './run.sh'`
      def fetch_and_unpack_exec(unit, working_directory)
        result = HTTP.get(unit[:exec_zip])
        file = Tempfile.new('orchestration-unit')
        while(data = result.body.readpartial(2048))
          file.write data
        end
        file.flush
        file.rewind
        asset_store.unpack(file, working_directory)
        unit[:exec] = File.join(working_directory, 'run.sh')
        unit
      end

      # Run the unit and set result information into response
      #
      # @param unit [Hash] orchestration unit
      # @param working_directory [String] path to local working directory
      # @param response [Hash] CFN response
      # @return [Hash] CFN response
      def run_unit(unit, working_directory, response)
        if(unit[:exec_zip])
          debug "Unit provided is compressed zip: #{unit[:exec_zip]}"
          fetch_and_unpack_exec(unit, working_directory)
        end
        if(unit[:exec])
          debug "Unit to execute: #{unit[:exec]}"
          result = Smash.new
          stdout = process_manager.create_io_tmp(Carnivore.uuid, 'stdout')
          stderr = process_manager.create_io_tmp(Carnivore.uuid, 'stderr')
          result[:start_time] = Time.now.to_i
          [unit[:exec]].flatten.each do |exec_command|
            debug "Command to execute: #{exec_command}"
            process_manager.process(unit.hash, exec_command) do |process|
              process.io.stdout = stdout
              process.io.stderr = stderr
              process.cwd = working_directory
              if(unit[:env])
                debug "Custom environment defined: #{unit[:env]}"
                process.environment.replace(unit[:env])
              end
              process.leader = true
              process.start
              begin
                process.poll_for_exit(config.fetch(:max_execution_time, 500))
                result[:exit_code] = process.exit_code
                break if result[:exit_code] != 0
                debug "Execution of command successful - #{exec_command}"
              rescue ChildProcess::TimeoutError
                process.stop
                result[:timed_out] = true
                result[:exit_code] = process.exit_code
              end
            end
          end
          result[:stop_time] = Time.now.to_i
          stdout.rewind
          if(stdout.size > MAX_RESULT_SIZE)
            warn "Command result greater than allowed size: #{stdout.size} > #{MAX_RESULT_SIZE}"
          end
          result[:content] = stdout.size > 0 ? stdout.readpartial(MAX_RESULT_SIZE) : ''
          if(result[:exit_code] != 0)
            debug "Execution of unit failed - #{unit}"
            stderr.rewind
            result[:error_message] = stderr.size > 0 ? stderr.readpartial(MAX_RESULT_SIZE) : ''
            stderr.rewind
            stdout.rewind
            debug "Failed unit STDOUT: #{stdout.read}"
            debug "Failed unit STDERR: #{stderr.read}"
          end
          if(result[:exit_code] == 0)
            response['Data']['OrchestrationUnitResult'] = result[:content]
            begin
              j_result = MultiJson.load(result[:content])
              response['Data'] = j_result.merge(response['Data'])
              unless(unit[:raw_result])
                response['Data'].delete('OrchestrationUnitResult')
              end
            rescue MultiJson::ParseError => e
              debug 'Command result not JSON data'
            end
            response
          else
            raise "Execution failed! Exit code: #{result[:exit_code]} Reason: #{result[:error_message]}"
          end
        else
          response['Data']['OrchestrationUnitResult'] = 'No command executed!'
          response
        end
      end

      # Extract unit information based on received request type
      #
      # @param request_type [String] CFN request type
      # @param parameters [Hash] resource parameters
      # @return [Hash] orchestration unit
      def unit_for(request_type, parameters)
        base_key = "on_#{request_type.to_s.downcase}"
        result = Smash.new
        if(direct_unit = parameters[base_key])
          direct_unit = rekey_hash(direct_unit)
          [:exec, :exec_zip, :env, :raw_result, :only_if, :not_if].each do |p_key|
            if(direct_unit[p_key])
              result[p_key] = direct_unit[p_key]
            end
          end
        end
        unless(result[:exec] || result[:exec_zip])
          if(parameters[:exec])
            result[:exec] = parameters[:exec]
          elsif(parameters[:exec_zip])
            result[:exec_zip] = parameters[:exec_zip]
          end
        end
        if(parameters[:env])
          if(result[:env])
            result[:env] = parameters[:env].merge(result[:env])
          else
            result[:env] = parameters[:env]
          end
        end
        unless(result.key?('raw_result'))
          result[:raw_result] = parameters.fetch('raw_result', true)
        end
        [:only_if, :not_if].each do |conditional_key|
          if(!result.key?(conditional_key) && parameters.key?(conditional_key))
            result[conditional_key] = parameters[conditional_key]
          end
        end
        result[:env] ||= Smash.new
        result[:env]['CFN_REQUEST_TYPE'] = request_type.to_s.upcase
        result
      end

    end
  end
end
