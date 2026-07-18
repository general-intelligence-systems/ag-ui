# frozen_string_literal: true

require "json"

module AgUi
  class Server
    module SSE
      # AG-UI SSE framing, ported from the reference encoder
      # (ag-ui sdks/python/ag_ui/encoder/encoder.py, cross-checked against
      # @ag-ui/encoder dist): one event per frame, `data: <json>\n\n`, no
      # `event:`/`id:` lines, no heartbeats. Keys are camelCase and nil
      # fields are omitted at every depth (pydantic exclude_none).
      class EventEncoder
        CONTENT_TYPE = "text/event-stream"

        def content_type = CONTENT_TYPE

        # event: a Hash with camelCase string/symbol keys, e.g.
        #   { type: "TEXT_MESSAGE_CONTENT", messageId: "m1", delta: "Hi" }
        def encode(event)
          "data: #{JSON.generate(strip_nils(event))}\n\n"
        end

        private

        def strip_nils(value)
          case value
          when Hash
            value.each_with_object({}) do |(k, v), out|
              unless v.nil?
                out[k] = strip_nils(v)
              end
            end
          when Array
            value.map { |v| strip_nils(v) }
          else
            value
          end
        end
      end
    end
  end
end

__END__

describe "ag_ui/server/sse/event_encoder" do
  encoder = AgUi::Server::SSE::EventEncoder.new

  it "frames an event as a single data line with a blank-line terminator" do
    frame = encoder.encode({ type: "TEXT_MESSAGE_CONTENT", messageId: "m1", delta: "Hi" })
    frame.should == "data: {\"type\":\"TEXT_MESSAGE_CONTENT\",\"messageId\":\"m1\",\"delta\":\"Hi\"}\n\n"
  end

  it "omits nil fields at every depth" do
    frame = encoder.encode({ type: "RUN_FINISHED", threadId: "t", runId: "r",
                             result: nil, nested: { keep: 1, drop: nil } })
    frame.should == "data: {\"type\":\"RUN_FINISHED\",\"threadId\":\"t\",\"runId\":\"r\",\"nested\":{\"keep\":1}}\n\n"
  end

  it "preserves nils inside arrays and keeps empty strings/false" do
    frame = encoder.encode({ type: "CUSTOM", name: "x", value: ["a", nil], flag: false, s: "" })
    frame.should == "data: {\"type\":\"CUSTOM\",\"name\":\"x\",\"value\":[\"a\",null],\"flag\":false,\"s\":\"\"}\n\n"
  end

  it "advertises the SSE content type" do
    encoder.content_type.should == "text/event-stream"
  end
end
