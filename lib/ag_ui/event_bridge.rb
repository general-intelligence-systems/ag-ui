# frozen_string_literal: true

require "bundler/setup"
require "ag_ui"

module AgUi
  # The seam between brute's turn pipeline and the AG-UI SSE stream.
  #
  # Brute middleware and terminal procs push `{type:, data:}` events into
  # env[:events]; an EventBridge is that sink, translating each event into
  # the matching typed SSE emitter as it arrives — the browser sees deltas
  # mid-turn, not after.
  #
  #   pipeline.start(messages, events: AgUi::EventBridge.new(stream))
  #
  # Unknown event types (brute's own :log, :tool_result telemetry, etc.)
  # are ignored — only the AG-UI vocabulary reaches the wire.
  class EventBridge
    TRANSLATIONS = {
      text_message_start: :translate_text_start,
      text_message_content: :translate_text_content,
      text_message_end: :translate_text_end,
      tool_call_start: :translate_tool_call_start,
      tool_call_args: :translate_tool_call_args,
      tool_call_end: :translate_tool_call_end,
      tool_call_result: :translate_tool_call_result,
      state_snapshot: :translate_state_snapshot,
      state_delta: :translate_state_delta,
      messages_snapshot: :translate_messages_snapshot,
      activity_snapshot: :translate_activity_snapshot,
      reasoning_start: :translate_reasoning_start,
      reasoning_message_start: :translate_reasoning_message_start,
      reasoning_message_content: :translate_reasoning_message_content,
      reasoning_message_end: :translate_reasoning_message_end,
      reasoning_end: :translate_reasoning_end,
      step_started: :translate_step_started,
      step_finished: :translate_step_finished,
      custom: :translate_custom,
      raw: :translate_raw,
    }.freeze

    def initialize(stream)
      @stream = stream
    end

    def <<(event)
      handler = TRANSLATIONS[event[:type]]
      if handler
        send(handler, event[:data] || {})
      end
      self
    end

    private

      def translate_text_start(data)
        @stream.text_message_start(message_id: data[:message_id])
      end

      # Protocol rule: TEXT_MESSAGE_CONTENT.delta must be non-empty —
      # providers occasionally emit empty chunks; drop them here.
      def translate_text_content(data)
        unless data[:delta].to_s.empty?
          @stream.text_message_content(message_id: data[:message_id], delta: data[:delta])
        end
      end

      def translate_text_end(data)
        @stream.text_message_end(message_id: data[:message_id])
      end

      def translate_tool_call_start(data)
        @stream.tool_call_start(
          tool_call_id: data[:tool_call_id],
          tool_call_name: data[:tool_call_name],
          parent_message_id: data[:parent_message_id],
        )
      end

      def translate_tool_call_args(data)
        unless data[:delta].to_s.empty?
          @stream.tool_call_args(tool_call_id: data[:tool_call_id], delta: data[:delta])
        end
      end

      def translate_tool_call_end(data)
        @stream.tool_call_end(tool_call_id: data[:tool_call_id])
      end

      def translate_tool_call_result(data)
        @stream.tool_call_result(
          message_id: data[:message_id],
          tool_call_id: data[:tool_call_id],
          content: data[:content],
        )
      end

      # Shared state (CoAgents). snapshot replaces the whole state; delta is a
      # JSON Patch (RFC 6902) op array the client applies to its own store.
      def translate_state_snapshot(data)
        @stream.state_snapshot(snapshot: data[:snapshot])
      end

      def translate_state_delta(data)
        @stream.state_delta(delta: data[:delta])
      end

      def translate_messages_snapshot(data)
        @stream.messages_snapshot(messages: data[:messages])
      end

      # Structured progress markers (paired start/finish by step name).
      def translate_step_started(data)
        @stream.step_started(step_name: data[:step_name])
      end

      def translate_step_finished(data)
        @stream.step_finished(step_name: data[:step_name])
      end

      # Escape hatches: CUSTOM carries app/agent-defined events (e.g. the
      # "PredictState" convention for predictive state updates); RAW passes a
      # framework event straight through.
      def translate_custom(data)
        @stream.custom(name: data[:name], value: data[:value])
      end

      def translate_raw(data)
        @stream.raw(event: data[:event], source: data[:source])
      end

      def translate_activity_snapshot(data)
        @stream.activity_snapshot(
          message_id: data[:message_id],
          activity_type: data[:activity_type],
          content: data[:content],
          replace: data.fetch(:replace, true),
        )
      end

      def translate_reasoning_start(data)
        @stream.reasoning_start(message_id: data[:message_id])
      end

      def translate_reasoning_message_start(data)
        @stream.reasoning_message_start(message_id: data[:message_id])
      end

      def translate_reasoning_message_content(data)
        unless data[:delta].to_s.empty?
          @stream.reasoning_message_content(message_id: data[:message_id], delta: data[:delta])
        end
      end

      def translate_reasoning_message_end(data)
        @stream.reasoning_message_end(message_id: data[:message_id])
      end

      def translate_reasoning_end(data)
        @stream.reasoning_end(message_id: data[:message_id])
      end
  end
end

__END__

describe "AgUi::EventBridge" do
  read_frames = ->(stream) do
    frames = []
    while (chunk = stream.read)
      frames << JSON.parse(chunk.sub(/\Adata: /, "").strip)
    end
    frames
  end

  it "translates text events into SSE frames as they arrive" do
    stream = AgUi::Server::SSE::Stream.new(thread_id: "t1", run_id: "r1")
    bridge = AgUi::EventBridge.new(stream)

    bridge << { type: :text_message_start, data: { message_id: "m1" } }
    bridge << { type: :text_message_content, data: { message_id: "m1", delta: "Hel" } }
    bridge << { type: :text_message_content, data: { message_id: "m1", delta: "lo" } }
    bridge << { type: :text_message_end, data: { message_id: "m1" } }
    stream.finish

    frames = read_frames.(stream)
    frames.map { |f| f["type"] }.should == %w[
      TEXT_MESSAGE_START TEXT_MESSAGE_CONTENT TEXT_MESSAGE_CONTENT TEXT_MESSAGE_END
    ]
    frames[1]["delta"].should == "Hel"
  end

  it "drops empty deltas (protocol rule)" do
    stream = AgUi::Server::SSE::Stream.new(thread_id: "t1", run_id: "r1")
    bridge = AgUi::EventBridge.new(stream)

    bridge << { type: :text_message_content, data: { message_id: "m1", delta: "" } }
    bridge << { type: :text_message_content, data: { message_id: "m1", delta: nil } }
    stream.finish

    read_frames.(stream).should == []
  end

  it "ignores brute telemetry and unknown event types, returning self" do
    stream = AgUi::Server::SSE::Stream.new(thread_id: "t1", run_id: "r1")
    bridge = AgUi::EventBridge.new(stream)

    result = bridge << { type: :log, data: { note: "internal" } }
    bridge << { type: :whatever }
    stream.finish

    result.should.equal?(bridge)
    read_frames.(stream).should == []
  end

  it "translates shared-state events (snapshot + JSON-Patch delta)" do
    stream = AgUi::Server::SSE::Stream.new(thread_id: "t1", run_id: "r1")
    bridge = AgUi::EventBridge.new(stream)

    bridge << { type: :state_snapshot, data: { snapshot: { "theme" => "dark" } } }
    bridge << { type: :state_delta,
                data: { delta: [{ "op" => "replace", "path" => "/theme", "value" => "light" }] } }
    stream.finish

    frames = read_frames.(stream)
    frames.map { |f| f["type"] }.should == %w[STATE_SNAPSHOT STATE_DELTA]
    frames[0]["snapshot"].should == { "theme" => "dark" }
    frames[1]["delta"].first["path"].should == "/theme"
  end

  it "translates CUSTOM (e.g. the PredictState convention) and STEP markers" do
    stream = AgUi::Server::SSE::Stream.new(thread_id: "t1", run_id: "r1")
    bridge = AgUi::EventBridge.new(stream)

    bridge << { type: :step_started, data: { step_name: "plan" } }
    bridge << { type: :custom,
                data: { name: "PredictState",
                        value: [{ "state_key" => "document", "tool" => "write" }] } }
    bridge << { type: :step_finished, data: { step_name: "plan" } }
    stream.finish

    frames = read_frames.(stream)
    frames.map { |f| f["type"] }.should == %w[STEP_STARTED CUSTOM STEP_FINISHED]
    frames[0]["stepName"].should == "plan"
    frames[1]["name"].should == "PredictState"
  end
end
