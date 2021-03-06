require 'jackal'
require 'jackal-cfn/version'

module Jackal
  # Cfn entry system
  module Cfn
    autoload :Event, 'jackal-cfn/event'
    autoload :Resource, 'jackal-cfn/resource'
    autoload :Utils, 'jackal-cfn/utils'

    # Provided custom resources
    autoload :HashExtractor, 'jackal-cfn/resource/hash_extractor'
    autoload :AmiManager, 'jackal-cfn/resource/ami_manager'
    autoload :AmiRegister, 'jackal-cfn/resource/ami_register'
    autoload :JackalStack, 'jackal-cfn/resource/jackal_stack'
    autoload :OrchestrationUnit, 'jackal-cfn/resource/orchestration_unit'
    autoload :Scrubber, 'jackal-cfn/resource/scrubber'
  end
end
