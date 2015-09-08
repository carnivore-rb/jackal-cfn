# Jackal CFN

Provides jackal integration for AWS CloudFormation custom
resources and stack event notifications.

## Requirements

This library currently uses the `patron` gem for sending
notifications to AWS S3. It requires the curl development
libraries to be available, so ensure it is installed.

## Usage

There are two ways to use this library. The first is to process
events and resources into proper payloads and inject them into the
pipeline. The other is to re-process a formatted payload.

### Pipeline Injection

Configuration for pipeline injection of resource and event notifications
is very straightforward:

```json
{
  "jackal": {
    "cfn": {
      "config": {
      },
      "sources": {
        "input": {
          "type": "sqs",
          "args": {
            SQS_CONFIG
          }
        },
        "output": {
          OUTPUT_SOURCE
        }
      },
      "callbacks": [
        "Jackal::Cfn::Resource",
        "Jackal::Cfn::Event"
      ]
    }
  }
}
```

With this configuration in place resources and events will be received,
formatted, and delivered to the `OUTPUT_SOURCE`. It will be the job of
a later service to handle reply notifications (for resources) in this
style of usage.

### Message Reprocessing

When using the re-processing configuration, messages do not continue
down the pipeline. Instead, the original message is received, formatted,
and then re-delivered to the originating source (generally an SQS queue).
The message will be fetched again (this time properly formatted) and
any matching callbacks will be executed. A sample configuration may look
something like this:

```json
{
  "jackal": {
    "cfn": {
      "config": {
        "reprocess": true,
        "ami": {
          "credentials": {
            CREDENTIALS
          }
        }
      },
      "sources": {
        "input": {
          "type": "sqs",
          "args": {
            SQS_CONFIG
          }
        },
        "output": {
          OUTPUT_SOURCE
        }
      },
      "callbacks": [
        "Jackal::Cfn::Resource",
        "Jackal::Cfn::AmiRegister"
      ]
    }
  }
}
```

The important item to note is the `"reprocess": true` which enables the
automatic re-processing of messages.

## Custom Resources

This library provides support for creating new custom resources. Creation
is as simple as subclassing:

```ruby
module Jackal
  module Cfn
    class LocalPrinter < Jackal::Cfn::Resource

      def execute(message)
        failure_wrap(message) do |payload|
          cfn_resource = rekey_hash(payload.get(:data, :cfn_resource))
          cfn_response = build_response(cfn_resource)
          info "CFN Resource: #{cfn_resource.inspect}"
          info "CFN Response: #{cfn_response.inspect}"
          respond_to_stack(cfn_response, cfn_resource[:response_url])
        end
      end

    end
  end
end
```

This will match `Custom::LocalPrinter` resource requests that are received. It
will print information into the log about the request and then send a successful
response back to the stack.

### Builtin Custom Resources

This library provides a few custom resources builtin. These can be used directly or
as examples for building new custom resources.

#### `Jackal::Cfn::AmiRegister`

Generates and registers an AMI based on an EC2 resource. This allows for building a
single EC2 resource within a stack that is fully configured, creating and registering
an AMI based on that EC2 resource, and using the new AMI for instances created within
an ASG. It is an integrated way to speed up ASG instance launches, but keep all resources
for the stack fully managed.

Resource usage:

```json
{
  "Type": "Custom::AmiRegister",
  "Properties": {
    "Parameters": {
      "Name": String,
      "InstanceId": String,
      "Description": String,
      "NoReboot": Boolean,
      "BlockDeviceMappings": Array,
      "HaltInstance": Boolean,
      "Region": String
    }
  }
}
```

Resource Response:

```json
{
  "AmiId": String
}
```

Configuration:

```json
{
  "jackal": {
    "cfn": {
      "config": {
        "ami": {
          "credentials": {
            "compute": {
              FOG_CREDENTIALS
            }
          }
        }
      }
    }
  }
}
```

#### `Jackal::Cfn::AmiManager`

This resource is a simplification of the `AmiRegister` resource. The
`AmiManager` is used to ensure an AMI is removed from the system when
a stack is destroyed. This allows for customized AMI generation to be
integrated and ensure that once the stack is destroyed all custom AMIs
for that stack are destroyed as well.

Resource usage:

```json
{
  "Type": "Custom::AmiManager",
  "Properties": {
    "Parameters": {
      "AmiId": "",
      "Region": ""
    }
  }
}
```

Resource Response:

```json
{
}
```

Configuration:

```json
{
  "jackal": {
    "cfn": {
      "config": {
        "ami": {
          "credentials": {
            "compute": {
              FOG_CREDENTIALS
            }
          }
        }
      }
    }
  }
}
```

#### `Jackal::Cfn::HashExtractor`

This resource will extract a nested hash value from a JSON string. Useful
for when a result may be serialized JSON and a value from that structure
is required elsewhere.

Resource usage:

```json
{
  "Type": "Custom::HashExtractor",
  "Properties": {
    "Parameters": {
      "Key": "path.to.value.in.hash",
      "Value": JSON
    }
  }
}
```

Resource Response:

```json
{
  "Payload": VALUE
}
```

#### `Jackal::Cfn::JackalStack`

This resource provides an integration point for building stacks
on remote endpoints. Remote end points are provided via configuration
and referenced via the `Location` property in the custom resource.

Resource usage:

```json
{
  "Type": "Custom::JackalStack",
  "Properties": {
    "Parameters": {
      STACK_PARAMETERS
    },
    "Location": LOCATION,
    "TemplateURL": URL
  }
}
```

Resource Response:

The outputs of the stack will be proxied:

```json
{
  "Outputs.OUTPUT_NAME": "OUTPUT_VALUE"
}
```

Configuration:

```json
{
  "jackal": {
    "cfn": {
      "config": {
        "jackal_stack": {
          "credentials": {
            "storage": {
              TEMPLATE_S3_CREDENTIALS
            },
            LOCATION: {
              "provider": NAME,
              MIASMA_CREDENTIALS
            }
          }
        }
      }
    }
  }
}
```

## Info

* Repository: https://github.com/carnviore-rb/jackal-cfn
* IRC: Freenode @ #carnivore