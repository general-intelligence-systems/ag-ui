# frozen_string_literal: true

require "bundler/setup"
require "ag_ui"

module AgUi
  # Parses and validates the POST body of /agent/:id/run — the
  # RunAgentInput envelope (threadId, runId, messages, tools, context,
  # forwardedProps, state, resume?).
  #
  # Validation runs against the RAW parsed hash so explicit nulls
  # (state: null, forwardedProps: null) survive — Definition#to_h
  # compacts nils away, which would fail required-field checks.
  # The returned Definition gives snake_case readers and pattern
  # matching over the same data.
  #
  #   input = AgUi::RunInput.parse(request_body)
  #   input.thread_id  #=> "t1"
  #   input.messages   #=> [Definition(UserMessage), ...]
  #
  module RunInput
    # Raised on malformed JSON or schema-invalid input. The route layer
    # renders this as 400 {"error": "Invalid request body", "details": ...}.
    class InvalidError < StandardError; end

    SCHEMA_REF = "#/definitions/RunAgentInput"

    class << self
      def parse(body)
        begin
          raw = JSON.parse(body)
        rescue JSON::ParserError => e
          raise InvalidError, "malformed JSON: #{e.message}"
        end

        unless raw.is_a?(Hash)
          raise InvalidError, "expected a JSON object, got #{raw.class}"
        end

        errors = schema.validate(raw).to_a
        unless errors.empty?
          validation_error = Protocol::JsonSchema::ValidationError.new(
            errors,
            definition_name: "RunAgentInput",
            data: raw,
          )
          raise InvalidError, validation_error.message
        end

        Protocol::JsonSchema["RunAgentInput"].new(raw)
      end

      def schema
        @schema ||= Protocol::JsonSchema.schemer.ref(SCHEMA_REF)
      end
    end
  end
end

__END__

describe "AgUi::RunInput" do
  minimal = {
    "threadId" => "t1", "runId" => "r1", "state" => nil,
    "messages" => [], "tools" => [], "context" => [], "forwardedProps" => nil,
  }

  it "parses a minimal valid body with explicit nulls" do
    input = AgUi::RunInput.parse(JSON.generate(minimal))
    input.thread_id.should == "t1"
    input.run_id.should == "r1"
    input.messages.should == []
  end

  it "parses the full envelope: messages, tools, context" do
    body = minimal.merge(
      "messages" => [
        { "id" => "u1", "role" => "user", "content" => "hi" },
        { "id" => "a1", "role" => "assistant",
          "toolCalls" => [{ "id" => "tc1", "type" => "function",
                            "function" => { "name" => "navigate", "arguments" => "{}" } }] },
        { "id" => "tr1", "role" => "tool", "content" => "{}", "toolCallId" => "tc1" },
      ],
      "tools" => [{ "name" => "navigate", "description" => "Go to a page",
                    "parameters" => { "type" => "object" } }],
      "context" => [{ "description" => "currentPath", "value" => "/data" }],
    )

    input = AgUi::RunInput.parse(JSON.generate(body))
    input.messages.length.should == 3
    input.tools.first.name.should == "navigate"
    input.context.first.value.should == "/data"

    # Messages are a discriminated union — they stay raw camelCase hashes.
    input.messages.last["toolCallId"].should == "tc1"

    case input
    in { thread_id: String => tid }
      tid.should == "t1"
    end
  end

  it "accepts multimodal user message content parts" do
    body = minimal.merge(
      "messages" => [
        { "id" => "u1", "role" => "user", "content" => [
          { "type" => "text", "text" => "what is this?" },
          { "type" => "image",
            "source" => { "type" => "data", "value" => "aGk=", "mimeType" => "image/png" } },
        ] },
      ],
    )

    input = AgUi::RunInput.parse(JSON.generate(body))
    input.messages.first["content"].length.should == 2
  end

  it "tolerates unknown extra fields (extra=allow)" do
    input = AgUi::RunInput.parse(JSON.generate(minimal.merge("lastSeenEventId" => "5")))
    input.thread_id.should == "t1"
  end

  it "rejects malformed JSON" do
    begin
      AgUi::RunInput.parse("{nope")
      raise "expected InvalidError"
    rescue AgUi::RunInput::InvalidError => e
      e.message.should.include?("malformed JSON")
    end
  end

  it "rejects non-object bodies" do
    begin
      AgUi::RunInput.parse("[1,2]")
      raise "expected InvalidError"
    rescue AgUi::RunInput::InvalidError => e
      e.message.should.include?("expected a JSON object")
    end
  end

  it "rejects schema-invalid bodies with readable details" do
    begin
      AgUi::RunInput.parse(JSON.generate({ "threadId" => "t1" }))
      raise "expected InvalidError"
    rescue AgUi::RunInput::InvalidError => e
      e.message.should.include?("runId")
    end
  end
end
