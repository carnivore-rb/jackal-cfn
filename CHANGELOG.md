# v0.2.18
* [feature] Add OrchestrationUnit resource

# v0.2.16
* [feature] Allow image re-registration when options provided
* [enhancement] Add resource scrubber helper

# v0.2.14
* [fix] Update variable name used in stack resource name construction

# v0.2.12
* Update joiner used for physical resource ID in JackalStack
* Support stack delete when create is incomplete

# v0.2.10
* Properly handle no parameters in properties
* Add new JackalStack resource

# v0.2.8
* Fix optional instance halt to wait for ami AVAILABLE state

# v0.2.6
* Fix event re-processing (destination generation)

# v0.2.4
* Add AmiRegister callback
* Update initial payload handling

# v0.2.2
* Fix credentials location in configuration
* Fix namespacing when access fog constants

# v0.2.0
* Move builtin resources under single namespace
* Add custom failure wrap to resource to provide auto failure notification
* Fix endpoint url response in extractor resource

# v0.1.6
* Isolate event and resource to simple handle format and forward
* Move builtin custom resources within new module `CfnTools`
* Update `Resource` and `Event` to subclass gracefully

# v0.1.4
* Include ami manager resource (handle deletion of amis only for now)

# v0.1.2
* Include request id in response content
* Allow matching on class name to custom resource type

# v0.1.0
* Initial commit
