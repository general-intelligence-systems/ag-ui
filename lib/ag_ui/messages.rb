# frozen_string_literal: true

require "bundler/setup"
require "ag_ui"

module AgUi
  # Translates AG-UI wire messages (RunAgentInput.messages — raw camelCase
  # hashes) into brute's canonical Brute::Message log, ready for the turn
  # pipeline. This is where client-executed tool results re-enter the
  # conversation: the assistant's toolCalls and the matching tool messages
  # must round-trip faithfully or the model repeats calls (doc 03 gotchas).
  module Messages
    class << self
      def to_brute(wire_messages)
        log = Brute.log

        wire_messages.each do |message|
          case message["role"]
          in "user"
            log.user(text_content(message["content"]))
          in "assistant"
            log << assistant_message(message)
          in "tool"
            log.tool(message["content"].to_s, tool_call_id: message["toolCallId"])
          in "system" | "developer"
            log.system(message["content"].to_s)
          in "activity" | "reasoning"
            # Not part of the LLM conversation: activities render client-side
            # (phase 4) and reasoning is provider-managed (phase 5).
            nil
          end
        end

        log
      end

      private

        def assistant_message(message)
          tool_calls = message["toolCalls"]&.map do |tc|
            Brute::ToolCall.new(
              id: tc["id"],
              name: tc.dig("function", "name"),
              arguments: parse_arguments(tc.dig("function", "arguments")),
            )
          end

          Brute::Message.new(
            role: :assistant,
            content: message["content"],
            tool_calls: tool_calls,
          )
        end

        # Wire arguments are a JSON-encoded string (OpenAI shape);
        # Brute::ToolCall wants the parsed Hash.
        def parse_arguments(arguments)
          case arguments
          when nil then {}
          when Hash then arguments
          else
            begin
              JSON.parse(arguments.to_s)
            rescue JSON::ParserError
              {}
            end
          end
        end

        # Multimodal content arrives as an array of InputContent parts.
        # Phase 1 flattens text parts; media parts pass through to the
        # terminal in phase 5 (ruby_llm `with:`).
        def text_content(content)
          case content
          when Array
            parts = content.filter_map do |part|
              if part["type"] == "text"
                part["text"]
              end
            end
            parts.join("\n")
          else
            content.to_s
          end
        end
    end
  end
end

__END__

describe "AgUi::Messages.to_brute" do
  it "translates the core roles" do
    log = AgUi::Messages.to_brute([
      { "id" => "s1", "role" => "system", "content" => "be helpful" },
      { "id" => "u1", "role" => "user", "content" => "hi" },
      { "id" => "a1", "role" => "assistant", "content" => "hello!" },
    ])

    log.map(&:role).should == [:system, :user, :assistant]
    log.last.content.should == "hello!"
  end

  it "round-trips assistant toolCalls with parsed JSON arguments" do
    log = AgUi::Messages.to_brute([
      { "id" => "a1", "role" => "assistant", "content" => nil,
        "toolCalls" => [{ "id" => "tc1", "type" => "function",
                          "function" => { "name" => "navigate", "arguments" => "{\"path\":\"/data\"}" } }] },
      { "id" => "t1", "role" => "tool", "content" => "{\"ok\":true}", "toolCallId" => "tc1" },
    ])

    assistant = log.first
    assistant.tool_call?.should.be.true
    assistant.tool_calls.first.id.should == "tc1"
    assistant.tool_calls.first.name.should == "navigate"
    assistant.tool_calls.first.arguments.should == { "path" => "/data" }

    log.last.role.should == :tool
    log.last.tool_call_id.should == "tc1"
    log.last.content.should == "{\"ok\":true}"
  end

  it "tolerates malformed tool-call argument JSON" do
    log = AgUi::Messages.to_brute([
      { "id" => "a1", "role" => "assistant",
        "toolCalls" => [{ "id" => "tc1", "type" => "function",
                          "function" => { "name" => "x", "arguments" => "{nope" } }] },
    ])
    log.first.tool_calls.first.arguments.should == {}
  end

  it "flattens multimodal user content to its text parts" do
    log = AgUi::Messages.to_brute([
      { "id" => "u1", "role" => "user", "content" => [
        { "type" => "text", "text" => "what is this?" },
        { "type" => "image", "source" => { "type" => "url", "value" => "http://x/y.png" } },
        { "type" => "text", "text" => "please describe" },
      ] },
    ])
    log.first.content.should == "what is this?\nplease describe"
  end

  it "skips activity and reasoning messages" do
    log = AgUi::Messages.to_brute([
      { "id" => "act1", "role" => "activity", "activityType" => "a2ui-surface", "content" => {} },
      { "id" => "r1", "role" => "reasoning", "content" => "thinking..." },
      { "id" => "u1", "role" => "user", "content" => "hi" },
    ])
    log.map(&:role).should == [:user]
  end
end
