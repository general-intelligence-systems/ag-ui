# frozen_string_literal: true

require "bundler/setup"
require "ag_ui"

module AgUi
  module Protocol
    module JsonSchema
      # Base class for schema-validated AG-UI protocol objects.
      # Ported from a2a's Protocol::JsonSchema::Definition.
      #
      # Each AG-UI definition (RunAgentInput, TextMessageContentEvent, …)
      # gets a dynamically-generated subclass of Definition with:
      #   - A JSONSchemer sub-schema attached (.schema)
      #   - Reader methods for each property (snake_case)
      #   - Validation via .valid? / .valid!
      #
      # NOTE: #to_h deep-compacts nil values (matching pydantic's
      # exclude_none on the wire). Inbound payloads that carry explicit
      # nulls (e.g. RunAgentInput.state) should be validated as raw
      # hashes via JsonSchema.schemer, not round-tripped through here.
      class Definition
        def initialize(hash = {})
          props    = self.class.schema_properties
          snake    = self.class.snake_to_camel_map
          refs     = self.class.property_refs
          @data    = {}

          hash.each do |key, value|
            k = key.to_s

            # Resolve snake_case input to camelCase storage key
            camel = snake[k] || k

            if props.include?(camel)
              @data[camel] = if value.is_a?(Definition)
                value.to_h
              elsif (ref_info = refs[camel])
                wrap_ref(value, ref_info)
              else
                value
              end
            end
          end
        end

        # --- class methods overridden by the factory -----------------------

        def self.schema
          raise "AgUi::Protocol::JsonSchema::Definition should NOT be instantiated directly"
        end

        def self.definition_name
          raise "AgUi::Protocol::JsonSchema::Definition should NOT be instantiated directly"
        end

        def self.schema_properties
          raise "AgUi::Protocol::JsonSchema::Definition should NOT be instantiated directly"
        end

        def self.snake_to_camel_map
          raise "AgUi::Protocol::JsonSchema::Definition should NOT be instantiated directly"
        end

        def self.property_refs
          raise "AgUi::Protocol::JsonSchema::Definition should NOT be instantiated directly"
        end

        # Reverse of snake_to_camel_map. Built first-entry-wins: the
        # factory inserts the snake_case key before the camelCase
        # identity key, so camelCase storage keys map back to their
        # snake_case reader names.
        def self.camel_to_snake_map
          @camel_to_snake_map ||= snake_to_camel_map.each_with_object({}) do |(key, camel), map|
            map[camel] ||= key
          end
        end

        # --- validation ----------------------------------------------------

        def valid?
          self.class.schema.valid?(to_h)
        end

        def valid!
          errors = self.class.schema.validate(to_h).to_a

          if errors.empty?
            true
          else
            raise ValidationError.new(
              errors,
              definition_name: self.class.definition_name,
              data: to_h,
            )
          end
        end

        # --- serialization -------------------------------------------------

        # Returns the data as a plain Hash with camelCase string keys,
        # matching the JSON wire format. Nested Definition instances
        # are auto-coerced via deep_compact.
        def to_h
          deep_compact(@data)
        end

        def ==(other)
          other.is_a?(Definition) && to_h == other.to_h
        end

        # --- pattern matching ----------------------------------------------

        # Supports Ruby hash pattern matching with snake_case (or camelCase)
        # keys. Absent properties are omitted so patterns requiring them
        # fail to match; nested Definitions destructure recursively.
        def deconstruct_keys(keys)
          snake = self.class.snake_to_camel_map

          if keys
            keys.each_with_object({}) do |key, result|
              camel = snake[key.to_s] || key.to_s
              if @data.key?(camel)
                result[key] = @data[camel]
              end
            end
          else
            camel_to_snake = self.class.camel_to_snake_map
            @data.each_with_object({}) do |(camel, value), result|
              result[(camel_to_snake[camel] || camel).to_sym] = value
            end
          end
        end

        def inspect
          "#<#{self.class.definition_name} #{to_h.inspect}>"
        end

        private

          def wrap_ref(value, ref_info)
            kind, name = ref_info

            case kind
            when :object
              value.is_a?(Hash) ? AgUi::Protocol::JsonSchema[name].new(value) : value
            when :array
              if value.is_a?(Array)
                value.map { |el| el.is_a?(Hash) ? AgUi::Protocol::JsonSchema[name].new(el) : el }
              else
                value
              end
            when :map
              if value.is_a?(Hash)
                value.transform_values { |v| v.is_a?(Hash) ? AgUi::Protocol::JsonSchema[name].new(v) : v }
              else
                value
              end
            else
              value
            end
          end

          def deep_compact(obj)
            case obj
            when Hash
              obj.each_with_object({}) do |(k, v), result|
                compacted = deep_compact(v)
                unless compacted.nil?
                  result[k] = compacted
                end
              end
            when Array
              obj.map { |v| deep_compact(v) }
            when Definition
              obj.to_h
            else
              obj
            end
          end
      end
    end
  end
end

__END__

describe "AgUi::Protocol::JsonSchema::Definition" do
  schema = AgUi::Protocol::JsonSchema

  it "exposes snake_case readers over camelCase storage" do
    event = schema["ToolCallStartEvent"].new(
      type: "TOOL_CALL_START", tool_call_id: "tc1", tool_call_name: "navigate"
    )
    event.tool_call_id.should == "tc1"
    event.tool_call_name.should == "navigate"
    event.to_h["toolCallId"].should == "tc1"
  end

  it "supports hash pattern matching with snake_case keys" do
    event = schema["ToolCallStartEvent"].new(
      type: "TOOL_CALL_START", tool_call_id: "tc1", tool_call_name: "navigate"
    )

    case event
    in { tool_call_name: String => name }
      name.should == "navigate"
    end
  end

  it "wraps nested array refs into Definitions" do
    msg = schema["AssistantMessage"].new(
      id: "a1", role: "assistant",
      tool_calls: [{ "id" => "tc1", "type" => "function",
                     "function" => { "name" => "navigate", "arguments" => "{}" } }]
    )
    msg.tool_calls.first.should.be.kind_of(AgUi::Protocol::JsonSchema::Definition)
    msg.to_h["toolCalls"].first["function"]["name"].should == "navigate"
    msg.valid?.should == true
  end

  it "raises ValidationError with readable message on valid!" do
    event = schema["ToolCallStartEvent"].new(type: "TOOL_CALL_START", tool_call_id: "tc1")

    begin
      event.valid!
      raise "expected ValidationError"
    rescue AgUi::Protocol::JsonSchema::ValidationError => e
      e.message.should.include?("ToolCallStartEvent")
      e.message.should.include?("toolCallName")
    end
  end
end
