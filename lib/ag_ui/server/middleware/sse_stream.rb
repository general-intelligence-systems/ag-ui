# frozen_string_literal: true

require "bundler/setup"
require "ag_ui"
require "async"

module AgUi
  class Server
    module Middleware
      # Sets up an SSE stream builder on `env["ag_ui.stream"]`, ported
      # from a2a's Server::Middleware::SSEStream.
      #
      # The `open` block runs inside an Async fiber and the stream is
      # automatically finished when the block exits (even on exception).
      # If the handler never calls `open`, the builder is removed from env
      # so the response layer doesn't mistake it for a real stream.
      #
      # Usage (inside the /run handler):
      #
      #   env["ag_ui.stream"].open(thread_id:, run_id:) do |s|
      #     s.run_started
      #     s.text_message_content(message_id: "m1", delta: "Hi")
      #     s.run_finished
      #   end
      #
      class SSEStream
        def initialize(app)
          @app = app
        end

        def call(env)
          builder = StreamBuilder.new(env)
          env["ag_ui.stream"] = builder

          result = @app.call(env)

          # If open was never called, clear the builder so the response
          # layer doesn't mistake it for a real stream.
          if env["ag_ui.stream"].equal?(builder)
            env.delete("ag_ui.stream")
          end

          result
        end
      end

      # Factory that creates the SSE stream and runs the caller's block
      # inside Async with automatic finish on exit.
      #
      # Created by SSEStream middleware — not intended for direct use.
      class StreamBuilder
        def initialize(env)
          @env = env
        end

        # Create and open the SSE stream for the current run.
        #
        # The block runs inside an Async fiber; the stream is finished
        # when the block exits, even if an exception is raised. The run
        # handler owns terminal-event semantics (RUN_FINISHED / RUN_ERROR)
        # — this layer only guarantees the connection closes.
        def open(thread_id:, run_id:, validate: true, &block)
          stream = SSE::Stream.new(thread_id: thread_id, run_id: run_id, validate: validate)

          @env["ag_ui.stream"] = stream

          Async do
            block.call(stream)
          ensure
            stream.finish
          end

          nil
        end
      end
    end
  end
end

__END__

describe "AgUi::Server::Middleware::SSEStream" do
  it "sets a StreamBuilder on env and clears it when open is never called" do
    seen = nil
    mw = AgUi::Server::Middleware::SSEStream.new(->(env) { seen = env["ag_ui.stream"]; :ok })

    env = {}
    result = mw.call(env)

    seen.should.be.kind_of(AgUi::Server::Middleware::StreamBuilder)
    env.key?("ag_ui.stream").should == false
    result.should == :ok
  end

  it "preserves the opened stream on env" do
    mw = AgUi::Server::Middleware::SSEStream.new(->(env) do
      env["ag_ui.stream"].open(thread_id: "t1", run_id: "r1") { |s| s.run_started }
    end)

    env = {}
    mw.call(env)

    env["ag_ui.stream"].should.be.kind_of(AgUi::Server::SSE::Stream)
  end
end

describe "AgUi::Server::Middleware::StreamBuilder" do
  it "passes thread_id and run_id through to the stream" do
    env = {}
    builder = AgUi::Server::Middleware::StreamBuilder.new(env)

    builder.open(thread_id: "t1", run_id: "r1") do |s|
      s.thread_id.should == "t1"
      s.run_id.should == "r1"
    end
  end

  it "auto-finishes the stream when the block completes" do
    env = {}
    builder = AgUi::Server::Middleware::StreamBuilder.new(env)

    builder.open(thread_id: "t1", run_id: "r1") { |s| s.run_started }

    stream = env["ag_ui.stream"]
    stream.read.should.include?("RUN_STARTED")
    stream.read.should.be.nil
  end

  it "auto-finishes even when the block raises" do
    env = {}
    builder = AgUi::Server::Middleware::StreamBuilder.new(env)

    builder.open(thread_id: "t1", run_id: "r1") do |s|
      s.run_started
      raise "boom"
    end

    stream = env["ag_ui.stream"]
    stream.read.should.include?("RUN_STARTED")
    stream.read.should.be.nil
  end

  it "returns nil" do
    env = {}
    builder = AgUi::Server::Middleware::StreamBuilder.new(env)
    builder.open(thread_id: "t1", run_id: "r1") { |_s| }.should.be.nil
  end
end
