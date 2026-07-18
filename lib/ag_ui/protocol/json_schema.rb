# frozen_string_literal: true

require "bundler/setup"
require "ag_ui"

module AgUi
  module Protocol
    # Schema-validated AG-UI protocol objects, powered by json_schemer.
    # Same mechanism as a2a's Protocol::JsonSchema, over the schema bundle
    # generated from the reference Python SDK's pydantic models
    # (data/generate-ag-ui-schema.py -> data/ag_ui.json).
    #
    #   AgUi::Protocol::JsonSchema["TextMessageContentEvent"]
    #   #=> Class < Definition with .schema, .valid?, reader methods
    #
    #   AgUi::Protocol::JsonSchema.list_definitions
    #   #=> ["ActivityDeltaEvent", "ActivityMessage", ...]
    #
    module JsonSchema
      DATA_PATH = File.expand_path("../../../data/ag_ui.json", __dir__).freeze

      @definition_classes = {}
      @schemer = nil
      @raw_schema = nil

      class << self
        # Look up a definition by model class name.
        #
        #   AgUi::Protocol::JsonSchema["RunAgentInput"]
        #   #=> Class < Definition
        #
        def [](name)
          @definition_classes[name] ||= begin
            definitions = raw_schema.fetch("definitions", {})

            unless definitions.key?(name)
              raise "No AG-UI definition found for #{name.inspect}!" \
                "\nAvailable: #{list_definitions.join(", ")}"
            end

            ref_schema = schemer.ref("#/definitions/#{name}")
            build_definition_class(ref_schema, name, definitions[name])
          end
        end

        # All available definition names, sorted.
        def list_definitions
          raw_schema.fetch("definitions", {}).keys.sort
        end

        # Definition names for concrete events (have a const "type"),
        # mapped from wire event type to definition name:
        #
        #   { "TEXT_MESSAGE_CONTENT" => "TextMessageContentEvent", ... }
        #
        def event_types
          @event_types ||= raw_schema.fetch("definitions", {}).each_with_object({}) do |(name, defn), map|
            const = defn.dig("properties", "type", "const")
            if const
              map[const] = name
            end
          end.freeze
        end

        # The JSONSchemer instance for the full AG-UI schema bundle.
        def schemer
          @schemer ||= JSONSchemer.schema(raw_schema)
        end

        # The parsed schema hash (all $refs are already internal —
        # the generator emits #/definitions/... pointers).
        def raw_schema
          @raw_schema ||= JSON.parse(File.read(DATA_PATH))
        end

        # Reset all cached state (useful for tests).
        def reset!
          @definition_classes.clear
          @schemer = nil
          @raw_schema = nil
          @event_types = nil
        end

        private

          # Build a Definition subclass for a specific AG-UI type.
          def build_definition_class(schema_instance, definition_name, raw_definition)
            properties     = raw_definition.fetch("properties", {})
            camel_keys     = properties.keys
            snake_to_camel = build_snake_to_camel(camel_keys)
            prop_refs      = build_property_refs(properties)

            reader_pairs = camel_keys.map { |ck| [camel_to_snake(ck).to_sym, ck] }

            Class.new(Definition) do
              @schema            = schema_instance
              @definition_name   = definition_name
              @schema_properties = camel_keys
              @snake_to_camel    = snake_to_camel
              @property_refs     = prop_refs

              class << self
                def schema           = @schema
                def definition_name  = @definition_name
                def schema_properties = @schema_properties
                def snake_to_camel_map = @snake_to_camel
                def property_refs    = @property_refs
              end

              reader_pairs.each do |snake_sym, camel_key|
                define_method(snake_sym) { @data[camel_key] }
              end
            end
          end

          # Inspect each property's schema for $ref pointers and build a map
          # of { camelKey => [:kind, "DefinitionName"] } so Definition can
          # auto-wrap nested Hashes. Pydantic wraps optional properties in
          # anyOf [<schema>, {type: null}], so detection looks through the
          # first non-null anyOf variant.
          #
          #   :object — direct $ref
          #   :array  — items.$ref
          #   :map    — additionalProperties.$ref
          def build_property_refs(properties)
            definitions = raw_schema.fetch("definitions", {})
            refs = {}

            properties.each do |camel_key, prop_schema|
              schema = unwrap_optional(prop_schema)

              kind, ref =
                if (r = schema["$ref"])
                  [:object, r]
                elsif schema["type"] == "array" && (r = schema.dig("items", "$ref"))
                  [:array, r]
                elsif schema["type"] == "object" && (r = schema.dig("additionalProperties", "$ref"))
                  [:map, r]
                end

              if ref
                name = ref_name_for(ref)
                if name && definitions.dig(name, "properties")
                  refs[camel_key] = [kind, name]
                end
              end
            end

            refs
          end

          # Pydantic optional: anyOf [<schema>, {"type": "null"}] — return
          # the non-null variant (only when the anyOf is that exact shape).
          def unwrap_optional(prop_schema)
            variants = prop_schema["anyOf"]
            if variants
              non_null = variants.reject { |s| s == { "type" => "null" } }
              non_null.length == 1 ? non_null.first : prop_schema
            else
              prop_schema
            end
          end

          def ref_name_for(ref)
            if ref.start_with?("#/definitions/")
              ref.sub("#/definitions/", "")
            end
          end

          def build_snake_to_camel(camel_keys)
            map = {}
            camel_keys.each do |camel|
              snake = camel_to_snake(camel)
              map[snake] = camel
              map[camel] = camel
            end
            map
          end

          def camel_to_snake(str)
            str.gsub(/([A-Z])/) { "_#{$1.downcase}" }
               .delete_prefix("_")
          end
      end
    end
  end
end

__END__

describe "AgUi::Protocol::JsonSchema" do
  schema = AgUi::Protocol::JsonSchema

  it "loads the raw schema with definitions" do
    schema.raw_schema["definitions"].should.be.kind_of(Hash)
  end

  it "contains only internal $refs" do
    external = []
    walk = ->(obj) do
      case obj
      when Hash
        obj.each do |k, v|
          if k == "$ref" && v.is_a?(String) && !v.start_with?("#")
            external << v
          else
            walk.(v)
          end
        end
      when Array
        obj.each { |v| walk.(v) }
      end
    end
    walk.(schema.raw_schema["definitions"])
    external.should == []
  end

  it "lists definitions sorted, covering the core vocabulary" do
    defs = schema.list_definitions
    defs.should == defs.sort
    %w[RunAgentInput RunStartedEvent RunFinishedEvent TextMessageContentEvent
       ToolCallStartEvent ActivitySnapshotEvent AssistantMessage ToolMessage
       AgentCapabilities].each { |d| defs.should.include?(d) }
  end

  it "maps wire event types to definition names" do
    schema.event_types["TEXT_MESSAGE_CONTENT"].should == "TextMessageContentEvent"
    schema.event_types["RUN_STARTED"].should == "RunStartedEvent"
    schema.event_types["ACTIVITY_SNAPSHOT"].should == "ActivitySnapshotEvent"
  end

  it "returns cached Definition subclasses" do
    a = schema["RunStartedEvent"]
    b = schema["RunStartedEvent"]
    (a < AgUi::Protocol::JsonSchema::Definition).should == true
    a.object_id.should == b.object_id
  end

  it "builds definitions that serialize snake_case input to camelCase wire form" do
    event = schema["TextMessageContentEvent"].new(
      type: "TEXT_MESSAGE_CONTENT", message_id: "m1", delta: "Hi"
    )
    event.valid?.should == true
    event.to_h.should == { "type" => "TEXT_MESSAGE_CONTENT", "messageId" => "m1", "delta" => "Hi" }
  end

  it "rejects invalid events" do
    event = schema["TextMessageContentEvent"].new(type: "TEXT_MESSAGE_CONTENT", message_id: "m1")
    event.valid?.should == false
  end

  it "detects pydantic-optional anyOf refs as :object property refs" do
    schema["RunStartedEvent"].property_refs["input"].should == [:object, "RunAgentInput"]
  end

  it "validates RunAgentInput built via Definition" do
    input = schema["RunAgentInput"].new(
      thread_id: "t1", run_id: "r1", state: {}, messages: [],
      tools: [], context: [], forwarded_props: {}
    )
    input.valid?.should == true
    input.to_h["threadId"].should == "t1"
  end

  it "validates a raw wire hash with explicit nulls via schemer (inbound path)" do
    raw = { "threadId" => "t1", "runId" => "r1", "state" => nil, "messages" => [],
            "tools" => [], "context" => [], "forwardedProps" => nil, "extra" => 1 }
    schema.schemer.ref("#/definitions/RunAgentInput").valid?(raw).should == true
  end
end
