require 'jackal'
require 'jackal-cfn/version'

module Jackal
  # Cfn entry system
  module Cfn
    autoload :Event, 'jackal-cfn/event'
    autoload :Resource, 'jackal-cfn/resource'
  end
end
