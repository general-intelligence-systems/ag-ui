# frozen_string_literal: true

require "bundler/setup"
require "ag_ui"
require "protocol/http/body/writable"

module AgUi
  class Server
    module SSE
      # Async-native SSE body built on ::Protocol::HTTP::Body::Writable,
      # ported from a2a's Server::SSE::Stream with the AG-UI vocabulary.
      #
      # Falcon's protocol-rack passes Readable subclasses through untouched,
      # giving true async streaming with backpressure. write() pushes frames,
      # read() pops them (the HTTP server does this), close_write signals EOF.
      #
      # One typed emitter per AG-UI event, generated from the schema bundle:
      #
      #   stream = AgUi::Server::SSE::Stream.new(thread_id: "t1", run_id: "r1")
      #   stream.run_started
      #   stream.text_message_start(message_id: "m1", role: "assistant")
      #   stream.text_message_content(message_id: "m1", delta: "Hello")
      #   stream.text_message_end(message_id: "m1")
      #   stream.run_finished
      #   stream.finish
      #
      # threadId / runId are injected automatically wherever the event schema
      # has those properties (RUN_STARTED, RUN_FINISHED, ...); kwargs override.
      # Every event is schema-validated before hitting the wire (validate:
      # false to skip) — a wire-contract bug should raise, not stream.
      class Stream < ::Protocol::HTTP::Body::Writable
        # Response headers for the /run SSE response. Matches the Node
        # runtime (Cache-Control: no-cache, keep-alive) plus
        # x-accel-buffering to defeat proxy buffering.
        SSE_HEADERS = {
          "content-type"      => "text/event-stream",
          "cache-control"     => "no-cache",
          "x-accel-buffering" => "no",
          "connection"        => "keep-alive",
        }.freeze

        attr_reader :thread_id, :run_id

        # on_event: optional tap receiving every wire payload — the run
        # store records through it for /connect replay.
        def initialize(thread_id:, run_id:, validate: true, on_event: nil, **options)
          @thread_id = thread_id
          @run_id    = run_id
          @validate  = validate
          @on_event  = on_event
          @encoder   = EventEncoder.new
          super(**options)
        end

        # Emit a pre-built event payload (Hash with camelCase keys).
        def event(payload)
          @on_event&.call(payload)
          write(@encoder.encode(payload))
        end

        # Signal end-of-stream; the reader receives nil and closes the
        # SSE connection.
        def finish
          close_write
        end

        # A fresh mutable copy — upstream middleware mutates response
        # headers in place.
        def self.headers
          SSE_HEADERS.dup
        end

        # --- Typed event emitters -------------------------------------------
        #
        # One method per concrete event definition in the schema bundle,
        # named after the wire type: RUN_STARTED -> #run_started,
        # TEXT_MESSAGE_CONTENT -> #text_message_content, ...
        AgUi::Protocol::JsonSchema.event_types.each do |wire_type, definition_name|
          definition_class = AgUi::Protocol::JsonSchema[definition_name]
          injects_thread   = definition_class.schema_properties.include?("threadId")
          injects_run      = definition_class.schema_properties.include?("runId")

          # Pydantic serializes non-null field defaults onto the wire
          # (e.g. TEXT_MESSAGE_START carries role: "assistant" when
          # omitted); null defaults are dropped by exclude_none. Mirror
          # that: pre-fill non-null defaults, let kwargs override. Fields
          # whose schema is a const (e.g. REASONING_MESSAGE_START's
          # role: "reasoning") can only hold that value — fill them too,
          # matching the reference SDKs' constructor defaults.
          property_defaults = AgUi::Protocol::JsonSchema.raw_schema
            .dig("definitions", definition_name, "properties")
            .each_with_object({}) do |(camel, prop), defaults|
              value = prop["default"].nil? ? prop["const"] : prop["default"]
              unless value.nil?
                defaults[camel] = value
              end
            end

          define_method(wire_type.downcase) do |**kwargs|
            # "type" inserted first so it leads the wire JSON, like the
            # reference SDKs — keeps oracle byte-diffs quiet.
            defaults = { "type" => wire_type }.merge(property_defaults)
            if injects_thread
              defaults["threadId"] = @thread_id
            end
            if injects_run
              defaults["runId"] = @run_id
            end

            definition = definition_class.new(defaults.merge(kwargs))
            if @validate
              definition.valid!
            end

            event(definition.to_h)
          end
        end
      end
    end
  end
end

__END__

describe "AgUi::Server::SSE::Stream" do
  read_frames = ->(stream) do
    frames = []
    while (chunk = stream.read)
      frames << JSON.parse(chunk.sub(/\Adata: /, "").strip)
    end
    frames
  end

  it "emits the phase-1 minimum viable event sequence" do
    stream = AgUi::Server::SSE::Stream.new(thread_id: "t1", run_id: "r1")

    stream.run_started
    stream.text_message_start(message_id: "m1")
    stream.text_message_content(message_id: "m1", delta: "Hello")
    stream.text_message_end(message_id: "m1")
    stream.run_finished
    stream.finish

    frames = read_frames.(stream)
    frames.map { |f| f["type"] }.should == %w[
      RUN_STARTED TEXT_MESSAGE_START TEXT_MESSAGE_CONTENT TEXT_MESSAGE_END RUN_FINISHED
    ]
    frames.first.should == { "type" => "RUN_STARTED", "threadId" => "t1", "runId" => "r1" }
    frames[1]["role"].should == "assistant"
    frames[2]["delta"].should == "Hello"
  end

  it "frames every event as data:-only SSE" do
    stream = AgUi::Server::SSE::Stream.new(thread_id: "t1", run_id: "r1")
    stream.run_started
    stream.finish

    chunk = stream.read
    chunk.should.start_with("data: ")
    chunk.should.end_with("\n\n")
    chunk.lines.length.should == 2
  end

  it "injects thread/run ids only where the schema has them" do
    stream = AgUi::Server::SSE::Stream.new(thread_id: "t1", run_id: "r1")
    stream.tool_call_start(tool_call_id: "tc1", tool_call_name: "navigate")
    stream.finish

    frame = read_frames.(stream).first
    frame.should == {
      "type" => "TOOL_CALL_START", "toolCallId" => "tc1", "toolCallName" => "navigate",
    }
  end

  it "allows kwargs to override injected ids" do
    stream = AgUi::Server::SSE::Stream.new(thread_id: "t1", run_id: "r1")
    stream.run_finished(run_id: "override", result: { "ok" => true })
    stream.finish

    frame = read_frames.(stream).first
    frame["runId"].should == "override"
    frame["threadId"].should == "t1"
    frame["result"].should == { "ok" => true }
  end

  it "emits activity snapshots in the flat wire shape" do
    stream = AgUi::Server::SSE::Stream.new(thread_id: "t1", run_id: "r1")
    stream.activity_snapshot(
      message_id: "a2ui-surface-tc1",
      activity_type: "a2ui-surface",
      content: { "a2ui_operations" => [] },
      replace: true,
    )
    stream.finish

    frame = read_frames.(stream).first
    frame["messageId"].should == "a2ui-surface-tc1"
    frame["activityType"].should == "a2ui-surface"
    frame.key?("activity").should == false
  end

  it "raises ValidationError on schema-invalid events before writing" do
    stream = AgUi::Server::SSE::Stream.new(thread_id: "t1", run_id: "r1")

    begin
      stream.text_message_content(message_id: "m1") # missing delta
      raise "expected ValidationError"
    rescue AgUi::Protocol::JsonSchema::ValidationError => e
      e.message.should.include?("delta")
    end

    stream.finish
    stream.read.should.be.nil
  end

  it "skips validation when validate: false" do
    stream = AgUi::Server::SSE::Stream.new(thread_id: "t1", run_id: "r1", validate: false)
    stream.text_message_content(message_id: "m1")
    stream.finish

    read_frames.(stream).first["type"].should == "TEXT_MESSAGE_CONTENT"
  end

  it "provides the SSE response headers as a fresh mutable copy" do
    headers = AgUi::Server::SSE::Stream.headers
    headers["content-type"].should == "text/event-stream"
    headers["cache-control"].should == "no-cache"
    headers.frozen?.should == false
  end

  it "is a ::Protocol::HTTP::Body::Readable" do
    stream = AgUi::Server::SSE::Stream.new(thread_id: "t1", run_id: "r1")
    stream.is_a?(::Protocol::HTTP::Body::Readable).should == true
  end
end
