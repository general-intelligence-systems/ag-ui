# frozen_string_literal: true

require "bundler/setup"
require "securerandom"
require "console"
require "ag_ui"

module AgUi
  module Middleware
    # Brute-style turn middleware implementing both halves of the AG-UI
    # tool model (doc 03).
    #
    # Way in: advertises the run's client tool definitions
    # (RunAgentInput.tools) plus the app's SERVER tool definitions on
    # env[:tools] (idempotent — the loop re-enters this middleware every
    # iteration).
    #
    # Way out, per tool call the model made:
    #   - every call emits TOOL_CALL_START / ARGS / END
    #   - a SERVER tool ({name:, description:, parameters:, handler:})
    #     executes inline: its result is appended as a :tool message
    #     (Loop::ToolResult re-invokes the stack so the model continues
    #     the same run) and emitted as TOOL_CALL_RESULT — the Node
    #     runtime's exact shape
    #   - a CLIENT tool sets env[:should_exit]: the run ends with plain
    #     RUN_FINISHED and the browser executes it (multi-run model)
    #   - mixed turns: server tools still execute, but any client call
    #     ends the run
    class ToolRouter
      def initialize(app, tools: nil, server_tools: nil)
        @app = app
        @client_tools = tools || []
        @server_tools = (server_tools || []).to_h { |t| [t[:name].to_s, t] }
      end

      def call(env)
        advertise(env)

        @app.call(env)

        last = env[:messages].last
        if last.respond_to?(:tool_call?) && last.tool_call?
          route(env, last.tool_calls)
        end

        env
      end

      private

        def advertise(env)
          env[:tools] ||= []
          known = env[:tools].map { |d| definition_name(d) }

          definitions = @client_tools + @server_tools.values.map { |t| server_definition(t) }
          definitions.each do |definition|
            name = definition_name(definition)
            unless known.include?(name)
              env[:tools] << definition
              known << name
            end
          end
        end

        def definition_name(definition)
          if definition.respond_to?(:to_h)
            definition.to_h["name"]
          else
            definition["name"]
          end
        end

        def server_definition(tool)
          {
            "name" => tool[:name].to_s,
            "description" => tool[:description].to_s,
            "parameters" => tool[:parameters] || { "type" => "object" },
          }
        end

        def route(env, tool_calls)
          client_called = false

          tool_calls.each do |tool_call|
            emit_call(env[:events], tool_call)

            server = @server_tools[tool_call.name]
            if server
              execute_server_tool(env, tool_call, server)
            else
              client_called = true
            end
          end

          if client_called
            env[:should_exit] = true
          end
        end

        def emit_call(events, tool_call)
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

        def execute_server_tool(env, tool_call, tool)
          begin
            result = tool[:handler].call(tool_call.arguments)
          rescue => e
            Console.error(self, "server tool #{tool_call.name} raised: #{e.message}", e)
            result = { "error" => e.message }
          end

          content = result.is_a?(String) ? result : JSON.generate(result)
          env[:messages].tool(content, tool_call_id: tool_call.id)
          env[:events] << {
            type: :tool_call_result,
            data: {
              message_id: SecureRandom.uuid,
              tool_call_id: tool_call.id,
              content: content,
            },
          }
        end
    end
  end
end

__END__

describe "AgUi::Middleware::ToolRouter" do
  it "advertises client and server tools idempotently across iterations" do
    seen = nil
    server_tool = { name: "get_time", description: "Now", handler: -> (_args) { "12:00" } }
    mw = AgUi::Middleware::ToolRouter.new(
      ->(env) { seen = env[:tools] },
      tools: [{ "name" => "navigate" }],
      server_tools: [server_tool],
    )

    env = { messages: Brute.log, events: [] }
    mw.call(env)
    mw.call(env) # second loop iteration

    seen.map { |t| t["name"] }.should == %w[navigate get_time]
    seen.last["parameters"].should == { "type" => "object" }
  end

  it "executes server tools inline: tool message appended, result emitted, no exit" do
    server_tool = {
      name: "lookup",
      description: "Look something up",
      parameters: { "type" => "object" },
      handler: ->(args) { { "found" => args["id"] } },
    }
    terminal = ->(env) do
      env[:messages] << Brute::Message.new(
        role: :assistant, content: nil,
        tool_calls: [{ id: "tc1", name: "lookup", arguments: { "id" => 42 } }],
      )
    end

    env = { messages: Brute.log, events: [] }
    AgUi::Middleware::ToolRouter.new(terminal, server_tools: [server_tool]).call(env)

    env[:messages].last.role.should == :tool
    env[:messages].last.tool_call_id.should == "tc1"
    env[:messages].last.content.should == "{\"found\":42}"

    env[:events].map { |e| e[:type] }.should == %i[
      tool_call_start tool_call_args tool_call_end tool_call_result
    ]
    env[:events].last[:data][:content].should == "{\"found\":42}"
    env.key?(:should_exit).should == false
  end

  it "captures handler errors as the tool result" do
    server_tool = { name: "boom", description: "x", handler: ->(_a) { raise "kaput" } }
    terminal = ->(env) do
      env[:messages] << Brute::Message.new(
        role: :assistant, content: nil,
        tool_calls: [{ id: "tc1", name: "boom", arguments: {} }],
      )
    end

    env = { messages: Brute.log, events: [] }
    AgUi::Middleware::ToolRouter.new(terminal, server_tools: [server_tool]).call(env)

    env[:messages].last.content.should == "{\"error\":\"kaput\"}"
    env.key?(:should_exit).should == false
  end

  it "mixed turns execute server tools but still end the run for client calls" do
    server_tool = { name: "lookup", description: "x", handler: ->(_a) { "ok" } }
    terminal = ->(env) do
      env[:messages] << Brute::Message.new(
        role: :assistant, content: nil,
        tool_calls: [
          { id: "tc1", name: "lookup", arguments: {} },
          { id: "tc2", name: "navigate", arguments: { "path" => "/x" } },
        ],
      )
    end

    env = { messages: Brute.log, events: [] }
    AgUi::Middleware::ToolRouter.new(terminal, server_tools: [server_tool]).call(env)

    env[:should_exit].should == true
    env[:events].count { |e| e[:type] == :tool_call_result }.should == 1
  end

  it "emits TOOL_CALL events and exits when the turn ends on client tool calls" do
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
    env[:should_exit].should == true
  end

  it "does nothing on the way out for plain text turns" do
    env = { messages: Brute.log, events: [] }
    AgUi::Middleware::ToolRouter.new(->(e) { e[:messages].assistant("hi") }).call(env)

    env[:events].should == []
    env.key?(:should_exit).should == false
  end
end
