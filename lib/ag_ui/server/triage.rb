# frozen_string_literal: true

require "bundler/setup"
require "ag_ui"

module AgUi
  class Server
    # Resolves the incoming request to an AG-UI operation, mirroring the
    # Node runtime's suffix-matching fetch-router (doc 09 §2):
    #
    #   GET  …/info                        → "info"
    #   POST …/agent/:agentId/run          → "run"     (body = RunAgentInput)
    #   POST …/agent/:agentId/connect      → "connect" (body tolerated, not required)
    #   POST …/agent/:agentId/stop/:tid    → "stop"
    #   POST <mount root>                  → "run"     (bare AG-UI endpoint —
    #                                        what @ag-ui/client's HttpAgent
    #                                        POSTs when given a plain URL)
    #   OPTIONS *                          → 204 (permissive CORS preflight)
    #
    # Sets env["ag_ui.operation"], env["ag_ui.agent_id"] and, for runs,
    # env["ag_ui.input"] (parsed RunInput). Short-circuits 400 on a bad
    # run body and 404 on unknown routes — downstream only ever sees a
    # resolved operation.
    #
    # Works both mounted (Rails/Rack map set SCRIPT_NAME, PATH_INFO is
    # relative) and standalone: matching is on trailing path segments.
    class Triage
      AGENT_ROUTE = %r{/agent/(?<agent_id>[^/]+)/(?<action>run|connect)\z}
      STOP_ROUTE  = %r{/agent/(?<agent_id>[^/]+)/stop/(?<thread_id>[^/]+)\z}
      INFO_ROUTE  = %r{(\A|/)info\z}

      def initialize(app)
        @app = app
      end

      def call(env)
        method = env["REQUEST_METHOD"]
        path   = env["PATH_INFO"].to_s.chomp("/")

        if method == "OPTIONS"
          preflight
        elsif method == "GET" && path.match?(INFO_ROUTE)
          @app.call(env.merge("ag_ui.operation" => "info"))
        elsif method == "POST" && (m = path.match(STOP_ROUTE))
          @app.call(
            env.merge(
              "ag_ui.operation" => "stop",
              "ag_ui.agent_id" => m[:agent_id],
              "ag_ui.thread_id" => m[:thread_id],
            ),
          )
        elsif method == "POST" && (m = path.match(AGENT_ROUTE))
          dispatch_agent(env, m)
        elsif method == "POST" && path.empty?
          dispatch_bare_run(env)
        else
          not_found
        end
      end

      private

        def dispatch_bare_run(env)
          input = parse_input(env, required: true)

          @app.call(
            env.merge(
              "ag_ui.operation" => "run",
              "ag_ui.agent_id" => "default",
              "ag_ui.input" => input,
            ),
          )
        rescue RunInput::InvalidError => e
          bad_request(e.message)
        end

        def dispatch_agent(env, match)
          input = parse_input(env, required: match[:action] == "run")

          @app.call(
            env.merge(
              "ag_ui.operation" => match[:action],
              "ag_ui.agent_id" => match[:agent_id],
              "ag_ui.input" => input,
            ),
          )
        rescue RunInput::InvalidError => e
          bad_request(e.message)
        end

        # /run requires a valid RunAgentInput; /connect bodies are only
        # parsed opportunistically (the stub ignores them).
        def parse_input(env, required:)
          body = env["rack.input"]&.read.to_s

          if required
            RunInput.parse(body)
          else
            begin
              RunInput.parse(body)
            rescue RunInput::InvalidError
              nil
            end
          end
        end

        def preflight
          [204, {
            "access-control-allow-origin"  => "*",
            "access-control-allow-methods" => "GET, POST, OPTIONS",
            "access-control-allow-headers" => "*",
          }, []]
        end

        def bad_request(details)
          [400, { "content-type" => "application/json" },
           [JSON.generate({ "error" => "Invalid request body", "details" => details })]]
        end

        def not_found
          [404, { "content-type" => "application/json" },
           [JSON.generate({ "error" => "Not found" })]]
        end
    end
  end
end

__END__

describe "AgUi::Server::Triage" do
  minimal_input = JSON.generate({
    "threadId" => "t1", "runId" => "r1", "state" => nil,
    "messages" => [], "tools" => [], "context" => [], "forwardedProps" => nil,
  })

  seen = nil
  app = ->(env) { seen = env; [200, {}, ["ok"]] }
  triage = AgUi::Server::Triage.new(app)

  request = ->(method, path, body: "") do
    seen = nil
    triage.call({
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "rack.input" => StringIO.new(body),
    })
  end

  it "resolves GET /info" do
    request.("GET", "/info")
    seen["ag_ui.operation"].should == "info"
  end

  it "resolves /info under a mount prefix" do
    request.("GET", "/api/copilotkit/info")
    seen["ag_ui.operation"].should == "info"
  end

  it "resolves POST /agent/:id/run with a parsed input" do
    request.("POST", "/agent/default/run", body: minimal_input)
    seen["ag_ui.operation"].should == "run"
    seen["ag_ui.agent_id"].should == "default"
    seen["ag_ui.input"].thread_id.should == "t1"
  end

  it "resolves POST /agent/:id/stop/:threadId" do
    request.("POST", "/agent/default/stop/t99")
    seen["ag_ui.operation"].should == "stop"
    seen["ag_ui.thread_id"].should == "t99"
  end

  it "resolves POST /agent/:id/connect without requiring a valid body" do
    request.("POST", "/agent/default/connect", body: "")
    seen["ag_ui.operation"].should == "connect"
    seen["ag_ui.input"].should.be.nil
  end

  it "returns 400 with details for a bad run body" do
    status, _headers, body = request.("POST", "/agent/default/run", body: "{}")
    seen.should.be.nil
    status.should == 400
    parsed = JSON.parse(body.first)
    parsed["error"].should == "Invalid request body"
    parsed["details"].should.include?("threadId")
  end

  it "resolves a bare POST to the mount root as a run (HttpAgent shape)" do
    request.("POST", "/", body: minimal_input)
    seen["ag_ui.operation"].should == "run"
    seen["ag_ui.agent_id"].should == "default"
    seen["ag_ui.input"].thread_id.should == "t1"

    status, = request.("POST", "/", body: "{}")
    status.should == 400
  end

  it "returns 404 for unknown routes and wrong methods" do
    request.("GET", "/agent/default/run")[0].should == 404
    request.("POST", "/nope")[0].should == 404
    seen.should.be.nil
  end

  it "answers OPTIONS preflight with 204" do
    status, headers, _body = request.("OPTIONS", "/agent/default/run")
    status.should == 204
    headers["access-control-allow-origin"].should == "*"
  end
end
