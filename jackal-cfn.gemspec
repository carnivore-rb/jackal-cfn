$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__)) + '/lib/'
require 'jackal/version'
Gem::Specification.new do |s|
  s.name = 'jackal-cfn'
  s.version = Jackal::Cfn::VERSION.version
  s.summary = 'Message processing helper'
  s.author = 'Chris Roberts'
  s.email = 'code@chrisroberts.org'
  s.homepage = 'https://github.com/carnivore-rb/jackal-cfn'
  s.description = 'CFN callback helpers'
  s.require_path = 'lib'
  s.license = 'Apache 2.0'
  s.add_dependency 'jackal'
  s.add_dependency 'patron'
  s.files = Dir['lib/**/*'] + %w(jackal-cfn.gemspec README.md CHANGELOG.md CONTRIBUTING.md LICENSE)
end
