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
      activity_snapshot: :translate_activity_snapshot,
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

      def translate_activity_snapshot(data)
        @stream.activity_snapshot(
          message_id: data[:message_id],
          activity_type: data[:activity_type],
          content: data[:content],
          replace: data.fetch(:replace, true),
        )
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
end
