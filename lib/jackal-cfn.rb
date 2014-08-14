require 'jackal'
require 'jackal-cfn/version'

module Jackal
  # Cfn entry system
  module Cfn
    autoload :Event, 'jackal-cfn/event'
    autoload :Resource, 'jackal-cfn/resource'
    autoload :Utils, 'jackal-cfn/utils'
  end

  # Tools
  module CfnTools
    autoload :HashExtractor, 'jackal-cfn/resource/hash_extractor'
    autoload :AmiManager, 'jackal-cfn/resource/ami_manager'
  end
end
