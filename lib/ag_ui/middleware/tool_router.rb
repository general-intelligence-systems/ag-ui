# frozen_string_literal: true

require "bundler/setup"
require "ag_ui"

module AgUi
  module Middleware
    # Brute-style turn middleware implementing the client-tool half of the
    # AG-UI tool model (doc 03 — the heart of it).
    #
    # Way in: advertises the run's client tool definitions
    # (RunAgentInput.tools) on env[:tools] for the terminal to register
    # schema-only with its provider.
    #
    # Way out: when the terminal appended an assistant message carrying
    # tool calls, emits TOOL_CALL_START / TOOL_CALL_ARGS / TOOL_CALL_END
    # per call and sets env[:should_exit] — client tools END the run
    # (plain RUN_FINISHED, no result event); the browser executes them
    # and POSTs a fresh run with the tool results appended to history.
    #
    # Server-side tools (executed inline, TOOL_CALL_RESULT, loop
    # continues) land in phase 6 alongside Brute::Middleware::Loop.
    class ToolRouter
      def initialize(app, tools: nil)
        @app = app
        @client_tools = tools || []
      end

      def call(env)
        # Append — upstream middleware (A2ui) may have injected tools already.
        env[:tools] = (env[:tools] || []) + @client_tools

        @app.call(env)

        last = env[:messages].last
        if last.respond_to?(:tool_call?) && last.tool_call?
          last.tool_calls.each do |tool_call|
            emit_client_tool_call(env[:events], tool_call)
          end
          env[:should_exit] = true
        end

        env
      end

      private

        def emit_client_tool_call(events, tool_call)
          events << {
            type: :tool_call_start,
            data: { tool_call_id: tool_call.id, tool_call_name: tool_call.name },
          }
          events << {
            type: :tool_call_args,
            data: { tool_call_id: tool_call.id, delta: JSON.generate(tool_call.arguments) },
          }
          events << {
            type: :tool_call_end,
            data: { tool_call_id: tool_call.id },
          }
        end
    end
  end
end

__END__

describe "AgUi::Middleware::ToolRouter" do
  it "advertises client tools on env[:tools] on the way in" do
    seen = nil
    tools = [{ "name" => "navigate" }]
    mw = AgUi::Middleware::ToolRouter.new(->(env) { seen = env[:tools] }, tools: tools)
    mw.call({ messages: Brute.log, events: [] })

    seen.should == tools
  end

  it "emits TOOL_CALL events and exits when the turn ends on tool calls" do
    terminal = ->(env) do
      env[:messages] << Brute::Message.new(
        role: :assistant, content: nil,
        tool_calls: [
          { id: "tc1", name: "navigate", arguments: { "path" => "/data" } },
          { id: "tc2", name: "queryDataModel", arguments: { "model" => "contacts" } },
        ],
      )
    end

    env = { messages: Brute.log, events: [] }
    AgUi::Middleware::ToolRouter.new(terminal).call(env)

    env[:events].map { |e| e[:type] }.should == %i[
      tool_call_start tool_call_args tool_call_end
      tool_call_start tool_call_args tool_call_end
    ]
    env[:events][0][:data].should == { tool_call_id: "tc1", tool_call_name: "navigate" }
    env[:events][1][:data][:delta].should == "{\"path\":\"/data\"}"
    env[:events][3][:data][:tool_call_name].should == "queryDataModel"
    env[:should_exit].should == true
  end

  it "does nothing on the way out for plain text turns" do
    env = { messages: Brute.log, events: [] }
    AgUi::Middleware::ToolRouter.new(->(e) { e[:messages].assistant("hi") }).call(env)

    env[:events].should == []
    env.key?(:should_exit).should == false
  end
end
