# frozen_string_literal: true

require "bundler/setup"
require "console"
require "ag_ui"

require "ag_ui/server/info"
require "ag_ui/server/triage"

module AgUi
  # Rack application exposing the AG-UI runtime surface the CopilotKit
  # client expects (doc 09): /info, /agent/:id/run (SSE), /agent/:id/connect
  # (stub), /agent/:id/stop/:threadId (ack).
  #
  # The block is the run handler. It receives the rack env with
  # env["ag_ui.input"] (parsed RunAgentInput) and env["ag_ui.stream"]
  # (StreamBuilder) and drives the run:
  #
  #   app = AgUi.agent(agent_id: "default") do |env|
  #     input = env["ag_ui.input"]
  #     env["ag_ui.stream"].open(thread_id: input.thread_id, run_id: input.run_id) do |s|
  #       s.run_started
  #       s.text_message_start(message_id: "m1")
  #       s.text_message_content(message_id: "m1", delta: "Hello")
  #       s.text_message_end(message_id: "m1")
  #       s.run_finished
  #     end
  #   end
  #
  #   # config.ru / Rails: mount at the CopilotKit runtimeUrl
  #   map("/api/copilotkit") { run app }
  #
  class Server
    JSON_HEADERS = { "content-type" => "application/json" }.freeze

    def initialize(agent_id: "default", description: nil, a2ui_enabled: false,
                   info_overrides: {}, validate: true, &block)
      unless block
        raise ArgumentError, "Server requires a run-handler block"
      end

      @agent_id = agent_id
      @info = Info.payload(
        agent_id: agent_id,
        description: description,
        a2ui_enabled: a2ui_enabled,
        overrides: info_overrides,
      )
      @validate = validate
      @handler = block
      @app = build_app
    end

    def call(env)
      @app.call(env)
    end

    private

      def build_app
        server = self

        Rack::Builder.app do
          use AgUi::Server::Triage
          use AgUi::Server::Middleware::SSEStream
          run ->(env) { server.send(:dispatch, env) }
        end
      end

      def dispatch(env)
        case env["ag_ui.operation"]
        in "info"    then respond_info
        in "run"     then respond_run(env)
        in "connect" then respond_connect(env)
        in "stop"    then respond_stop(env)
        end
      end

      def respond_info
        [200, JSON_HEADERS.dup, [JSON.generate(@info)]]
      end

      # The handler opens env["ag_ui.stream"]; the opened stream becomes
      # the response body — Falcon streams it natively while the run's
      # Async fiber keeps writing.
      def respond_run(env)
        @handler.call(env)

        stream = env["ag_ui.stream"]
        if stream.is_a?(SSE::Stream)
          [200, SSE::Stream.headers, stream]
        else
          Console.error(self, "run handler completed without opening the stream")
          [500, JSON_HEADERS.dup, [JSON.generate({ "error" => "Internal error" })]]
        end
      rescue => e
        Console.error(self, "run handler raised #{e.class}: #{e.message}", e)
        [500, JSON_HEADERS.dup, [JSON.generate({ "error" => "Internal error" })]]
      end

      # Resume stub, matching the Node runtime's unknown-thread behaviour:
      # 200 text/event-stream that completes immediately (zero events).
      def respond_connect(env)
        input = env["ag_ui.input"]
        stream = SSE::Stream.new(
          thread_id: input&.thread_id.to_s,
          run_id: input&.run_id.to_s,
          validate: @validate,
        )
        stream.finish

        [200, SSE::Stream.headers, stream]
      end

      # Acknowledge the stop. Run cancellation lands with the run loop —
      # transport-level contract is a 200 JSON ack.
      def respond_stop(_env)
        [200, JSON_HEADERS.dup, [JSON.generate({})]]
      end
  end

  # One-call entrypoint, mirroring A2A.agent:
  #
  #   run AgUi.agent(agent_id: "default") { |env| ... }
  #
  def self.agent(**options, &block) = Server.new(**options, &block)
end

__END__

describe "AgUi::Server" do
  minimal_input = JSON.generate({
    "threadId" => "t1", "runId" => "r1", "state" => nil,
    "messages" => [], "tools" => [], "context" => [], "forwardedProps" => nil,
  })

  request = ->(app, method, path, body: "") do
    app.call({
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "rack.input" => StringIO.new(body),
    })
  end

  echo_agent = AgUi.agent(agent_id: "default") do |env|
    input = env["ag_ui.input"]
    env["ag_ui.stream"].open(thread_id: input.thread_id, run_id: input.run_id) do |s|
      s.run_started
      s.text_message_start(message_id: "m1")
      s.text_message_content(message_id: "m1", delta: "Hello")
      s.text_message_end(message_id: "m1")
      s.run_finished
    end
  end

  read_frames = ->(stream) do
    frames = []
    while (chunk = stream.read)
      frames << JSON.parse(chunk.sub(/\Adata: /, "").strip)
    end
    frames
  end

  it "requires a run-handler block" do
    lambda { AgUi::Server.new }.should.raise(ArgumentError)
  end

  it "serves GET /info with the runtime envelope" do
    status, headers, body = request.(echo_agent, "GET", "/info")
    status.should == 200
    headers["content-type"].should == "application/json"

    payload = JSON.parse(body.first)
    payload["agents"]["default"]["className"].should == "BuiltInAgent"
    payload["a2uiEnabled"].should == false
  end

  it "streams a run as SSE from the handler's stream" do
    status, headers, body = request.(echo_agent, "POST", "/agent/default/run", body: minimal_input)

    status.should == 200
    headers["content-type"].should == "text/event-stream"
    body.should.be.kind_of(AgUi::Server::SSE::Stream)

    frames = read_frames.(body)
    frames.map { |f| f["type"] }.should == %w[
      RUN_STARTED TEXT_MESSAGE_START TEXT_MESSAGE_CONTENT TEXT_MESSAGE_END RUN_FINISHED
    ]
    frames.first["threadId"].should == "t1"
  end

  it "serves /connect as an SSE stream that completes immediately" do
    status, headers, body = request.(echo_agent, "POST", "/agent/default/connect")
    status.should == 200
    headers["content-type"].should == "text/event-stream"
    body.read.should.be.nil
  end

  it "acks /stop with 200 JSON" do
    status, _headers, body = request.(echo_agent, "POST", "/agent/default/stop/t1")
    status.should == 200
    JSON.parse(body.first).should == {}
  end

  it "returns 400 for an invalid run body" do
    status, _headers, body = request.(echo_agent, "POST", "/agent/default/run", body: "{}")
    status.should == 400
    JSON.parse(body.first)["error"].should == "Invalid request body"
  end

  it "returns 500 when the handler never opens the stream" do
    lazy_agent = AgUi.agent { |_env| :did_nothing }
    status, _headers, body = request.(lazy_agent, "POST", "/agent/default/run", body: minimal_input)
    status.should == 500
    JSON.parse(body.first)["error"].should == "Internal error"
  end

  it "returns 500 when the handler raises before opening the stream" do
    angry_agent = AgUi.agent { |_env| raise "boom" }
    status, _headers, _body = request.(angry_agent, "POST", "/agent/default/run", body: minimal_input)
    status.should == 500
  end

  it "works under a mount prefix" do
    status, _headers, body = request.(echo_agent, "GET", "/api/copilotkit/info")
    status.should == 200
    JSON.parse(body.first)["mode"].should == "sse"
  end
end
