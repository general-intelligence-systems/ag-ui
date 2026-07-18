# frozen_string_literal: true

# Wire-conformance suite: the event serialization expectations from the
# official AG-UI protocol repo's Ruby SDK test suite
# (github.com/ag-ui-protocol/ag-ui @ 3a7433e,
# sdks/community/ruby/test — vendored verbatim in test/upstream/ruby-sdk/),
# adapted to drive OUR emitters. Every expected payload below is copied
# from upstream unchanged; only the construction side differs (their
# typed event classes vs our schema-generated Stream emitters).
#
# Run: bundle exec scampi test/conformance.rb   (or bin/test for everything)

require "bundler/setup"
require_relative "../lib/ag_ui"

__END__

describe "AG-UI wire conformance (upstream ruby-sdk expectations)" do
  # [emitter, kwargs, expected payload (verbatim from upstream)]
  # Emitters inject threadId/runId ("t1"/"r1") where the schema carries them.
  CASES = [
    [:text_message_start, { message_id: "m1" },
     { "type" => "TEXT_MESSAGE_START", "messageId" => "m1", "role" => "assistant" }],
    [:text_message_content, { message_id: "m1", delta: "hi" },
     { "type" => "TEXT_MESSAGE_CONTENT", "messageId" => "m1", "delta" => "hi" }],
    [:text_message_end, { message_id: "m1" },
     { "type" => "TEXT_MESSAGE_END", "messageId" => "m1" }],
    [:text_message_chunk, { message_id: "m1", role: "assistant", delta: "hi" },
     { "type" => "TEXT_MESSAGE_CHUNK", "messageId" => "m1", "role" => "assistant", "delta" => "hi" }],
    [:thinking_text_message_start, {},
     { "type" => "THINKING_TEXT_MESSAGE_START" }],
    [:thinking_text_message_content, { delta: "thinking" },
     { "type" => "THINKING_TEXT_MESSAGE_CONTENT", "delta" => "thinking" }],
    [:thinking_text_message_end, {},
     { "type" => "THINKING_TEXT_MESSAGE_END" }],
    [:tool_call_start, { tool_call_id: "tc1", tool_call_name: "search" },
     { "type" => "TOOL_CALL_START", "toolCallId" => "tc1", "toolCallName" => "search" }],
    [:tool_call_args, { tool_call_id: "tc1", delta: "{}" },
     { "type" => "TOOL_CALL_ARGS", "toolCallId" => "tc1", "delta" => "{}" }],
    [:tool_call_end, { tool_call_id: "tc1" },
     { "type" => "TOOL_CALL_END", "toolCallId" => "tc1" }],
    [:tool_call_chunk, { tool_call_id: "tc1", tool_call_name: "search", delta: "{}" },
     { "type" => "TOOL_CALL_CHUNK", "toolCallId" => "tc1", "toolCallName" => "search", "delta" => "{}" }],
    [:tool_call_result, { message_id: "m1", tool_call_id: "tc1", content: "ok" },
     { "type" => "TOOL_CALL_RESULT", "messageId" => "m1", "toolCallId" => "tc1", "content" => "ok" }],
    [:thinking_start, { title: "step" },
     { "type" => "THINKING_START", "title" => "step" }],
    [:thinking_end, {},
     { "type" => "THINKING_END" }],
    [:state_snapshot, { snapshot: { "a" => 1 } },
     { "type" => "STATE_SNAPSHOT", "snapshot" => { "a" => 1 } }],
    [:state_delta, { delta: [{ "op" => "add", "path" => "/a", "value" => 1 }] },
     { "type" => "STATE_DELTA", "delta" => [{ "op" => "add", "path" => "/a", "value" => 1 }] }],
    [:messages_snapshot, { messages: [{ "id" => "d1", "role" => "developer", "content" => "hi" }] },
     { "type" => "MESSAGES_SNAPSHOT",
       "messages" => [{ "id" => "d1", "role" => "developer", "content" => "hi" }] }],
    [:activity_snapshot, { message_id: "a1", activity_type: "progress", content: { "pct" => 10 } },
     { "type" => "ACTIVITY_SNAPSHOT", "messageId" => "a1", "activityType" => "progress",
       "content" => { "pct" => 10 }, "replace" => true }],
    [:activity_delta,
     { message_id: "a1", activity_type: "progress",
       patch: [{ "op" => "replace", "path" => "/pct", "value" => 20 }] },
     { "type" => "ACTIVITY_DELTA", "messageId" => "a1", "activityType" => "progress",
       "patch" => [{ "op" => "replace", "path" => "/pct", "value" => 20 }] }],
    [:raw, { event: { "x" => 1 }, source: "sdk" },
     { "type" => "RAW", "event" => { "x" => 1 }, "source" => "sdk" }],
    [:custom, { name: "custom", value: { "x" => 1 } },
     { "type" => "CUSTOM", "name" => "custom", "value" => { "x" => 1 } }],
    [:run_started, {},
     { "type" => "RUN_STARTED", "threadId" => "t1", "runId" => "r1" }],
    [:run_finished, { result: { "ok" => true } },
     { "type" => "RUN_FINISHED", "threadId" => "t1", "runId" => "r1", "result" => { "ok" => true } }],
    [:run_error, { message: "boom", code: "ERR" },
     { "type" => "RUN_ERROR", "message" => "boom", "code" => "ERR" }],
    [:step_started, { step_name: "s1" },
     { "type" => "STEP_STARTED", "stepName" => "s1" }],
    [:step_finished, { step_name: "s1" },
     { "type" => "STEP_FINISHED", "stepName" => "s1" }],
    [:reasoning_start, { message_id: "r1" },
     { "type" => "REASONING_START", "messageId" => "r1" }],
    [:reasoning_message_start, { message_id: "rm1" },
     { "type" => "REASONING_MESSAGE_START", "messageId" => "rm1", "role" => "reasoning" }],
    [:reasoning_message_content, { message_id: "rm1", delta: "step 1" },
     { "type" => "REASONING_MESSAGE_CONTENT", "messageId" => "rm1", "delta" => "step 1" }],
    [:reasoning_message_end, { message_id: "rm1" },
     { "type" => "REASONING_MESSAGE_END", "messageId" => "rm1" }],
    [:reasoning_message_chunk, { message_id: "rm1", delta: "step" },
     { "type" => "REASONING_MESSAGE_CHUNK", "messageId" => "rm1", "delta" => "step" }],
    [:reasoning_end, { message_id: "r1" },
     { "type" => "REASONING_END", "messageId" => "r1" }],
    [:reasoning_encrypted_value,
     { subtype: "message", entity_id: "e1", encrypted_value: "opaque" },
     { "type" => "REASONING_ENCRYPTED_VALUE", "subtype" => "message",
       "entityId" => "e1", "encryptedValue" => "opaque" }],
  ].freeze

  emit_payload = ->(emitter, kwargs) do
    stream = AgUi::Server::SSE::Stream.new(thread_id: "t1", run_id: "r1")
    stream.public_send(emitter, **kwargs)
    stream.finish
    JSON.parse(stream.read.sub(/\Adata: /, "").strip)
  end

  CASES.each do |(emitter, kwargs, expected)|
    it "#{expected["type"]} serializes exactly as upstream expects" do
      emit_payload.(emitter, kwargs).should == expected
    end
  end

  # Encoder framing expectations (upstream event_encoder_test.rb)

  it "advertises text/event-stream and frames data:-prefixed double-newline SSE" do
    stream = AgUi::Server::SSE::Stream.new(thread_id: "t1", run_id: "r1")
    AgUi::Server::SSE::EventEncoder.new.content_type.should == "text/event-stream"

    stream.text_message_content(message_id: "m1", delta: "hi")
    stream.finish

    sse = stream.read
    sse.start_with?("data: ").should == true
    sse.end_with?("\n\n").should == true
  end

  it "encodes camelCase keys and excludes nil values" do
    stream = AgUi::Server::SSE::Stream.new(thread_id: "t1", run_id: "r1")
    stream.tool_call_start(tool_call_id: "tc1", tool_call_name: "search", parent_message_id: nil)
    stream.finish

    payload = JSON.parse(stream.read.sub(/\Adata: /, "").strip)
    payload["toolCallId"].should == "tc1"
    payload["toolCallName"].should == "search"
    payload.key?("parentMessageId").should == false
  end

  # Validation expectations (upstream raises ArgumentError on missing
  # required fields; our schema layer raises ValidationError)

  it "rejects events missing required fields" do
    stream = AgUi::Server::SSE::Stream.new(thread_id: "t1", run_id: "r1")

    [
      -> { stream.text_message_end },
      -> { stream.tool_call_args(delta: "{}") },
      -> { stream.step_started },
      -> { stream.run_error },
    ].each do |attempt|
      attempt.should.raise(AgUi::Protocol::JsonSchema::ValidationError)
    end
  end
end
