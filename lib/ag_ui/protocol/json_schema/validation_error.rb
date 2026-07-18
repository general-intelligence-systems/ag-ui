# frozen_string_literal: true

require "bundler/setup"
require "ag_ui"

module AgUi
  module Protocol
    module JsonSchema
      # Raised when a Definition instance fails schema validation.
      # Ported from a2a. Collects JSONSchemer error details and formats
      # them as a human-readable list with dot-notation field paths.
      #
      #   TextMessageContentEvent validation failed:
      #     - delta is required but missing
      #
      class ValidationError < StandardError
        attr_reader :errors, :definition_name, :data

        def initialize(errors, definition_name:, data: nil)
          @errors          = errors
          @definition_name = definition_name
          @data            = data

          super(build_message)
        end

        private

          def build_message
            lines = errors.map { |e| "  - #{format_error(e)}" }
            "#{definition_name} validation failed:\n#{lines.join("\n")}"
          end

          def format_error(error)
            path  = format_path(error)
            type  = error["type"]

            case type
            when "required"
              missing = error.dig("details", "missing_keys")&.join(", ") || "unknown"
              if path.empty?
                "#{missing} is required but missing"
              else
                "#{path}.#{missing} is required but missing"
              end
            when "type"
              expected = Array(error.dig("schema", "type")).join(" or ")
              "#{path.empty? ? "(root)" : path} must be #{expected}"
            when "enum"
              allowed = error.dig("schema", "enum")&.join(", ") || "?"
              "#{path.empty? ? "(root)" : path} must be one of: #{allowed}"
            when "const"
              "#{path.empty? ? "(root)" : path} must be #{error.dig("schema", "const").inspect}"
            when "pattern"
              pattern = error.dig("schema", "pattern")
              "#{path.empty? ? "(root)" : path} must match pattern #{pattern}"
            when "format"
              fmt = error.dig("schema", "format")
              "#{path.empty? ? "(root)" : path} must be a valid #{fmt}"
            when "minimum", "maximum"
              "#{path.empty? ? "(root)" : path} #{error["error"]}"
            when "additionalProperties"
              "#{path.empty? ? "(root)" : path} has unknown properties"
            else
              detail = error["error"] || error["type"] || "invalid"
              "#{path.empty? ? "(root)" : path} #{detail}"
            end
          end

          # Convert a JSON pointer like "/toolCalls/0/function" to
          # dot notation like "toolCalls.0.function".
          def format_path(error)
            pointer = error["data_pointer"].to_s

            if pointer.empty? || pointer == "/"
              ""
            else
              pointer.delete_prefix("/").gsub("/", ".")
            end
          end
      end
    end
  end
end

__END__

describe "AgUi::Protocol::JsonSchema::ValidationError" do
  error_data = [
    {
      "data_pointer" => "",
      "type" => "required",
      "details" => { "missing_keys" => ["delta"] },
      "schema" => {},
      "error" => "missing keys: delta"
    }
  ]

  err = AgUi::Protocol::JsonSchema::ValidationError.new(
    error_data, definition_name: "TextMessageContentEvent"
  )

  it "includes the definition name and formats required errors" do
    err.message.should.include?("TextMessageContentEvent")
    err.message.should.include?("delta is required but missing")
  end

  it "stores errors and definition name" do
    err.errors.should == error_data
    err.definition_name.should == "TextMessageContentEvent"
  end

  nested = AgUi::Protocol::JsonSchema::ValidationError.new(
    [{ "data_pointer" => "/function/name", "type" => "type",
       "schema" => { "type" => "string" }, "error" => "wrong type" }],
    definition_name: "ToolCall"
  )

  it "formats nested paths with dot notation" do
    nested.message.should.include?("function.name must be string")
  end
end
