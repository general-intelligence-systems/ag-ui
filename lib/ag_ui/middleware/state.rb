# frozen_string_literal: true

require "bundler/setup"
require "securerandom"
require "hana"
require "ag_ui"

module AgUi
  module Middleware
    # Shared state (CoAgents) — the Ruby side of AG-UI's STATE_SNAPSHOT /
    # STATE_DELTA channel (doc 05). Bidirectional state sync between the
    # frontend's `agent.state` and the running agent.
    #
    # Way in:
    #   - seeds env[:state] from RunAgentInput.state (the state the frontend
    #     last held, pushed via agent.setState) so downstream middleware,
    #     tools, and the app can READ what the UI currently shows
    #   - injects two tools the model calls to WRITE state:
    #       AGUISendStateSnapshot({ snapshot })  — replace the whole state
    #       AGUISendStateDelta({ delta })        — RFC 6902 JSON Patch ops
    #
    # Way out, per state-tool call the model made:
    #   - snapshot: env[:state] = snapshot; emits STATE_SNAPSHOT
    #   - delta:    patches env[:state] (Hana); emits STATE_DELTA
    #   - both append a {"status":"ok"} :tool message and emit a
    #     TOOL_CALL_RESULT — the same shape a server tool produces — then let
    #     the run CONTINUE (unlike a browser/client tool) so the model can act
    #     on the new state or confirm to the user. State tools are server-side.
    #
    # The TOOL_CALL_START/ARGS/END chrome is left to ToolRouter (it advertises
    # nothing about these being "client" vs "server" — it just streams the
    # call), exactly as A2ui leaves its render_a2ui call to ToolRouter. Compose
    # State OUTSIDE ToolRouter:
    #
    #   use Loop::ToolResult
    #   use State, state: input.state
    #   use ToolRouter, tools: input.tools
    #
    # The frontend applies the same snapshot/patch to its own store; env[:state]
    # is kept coherent so the agent's own later reads (and further deltas) see
    # the current value.
    class State
      SNAPSHOT_TOOL = "AGUISendStateSnapshot"
      DELTA_TOOL    = "AGUISendStateDelta"
      TOOL_NAMES    = [SNAPSHOT_TOOL, DELTA_TOOL].freeze

      SNAPSHOT_DEFINITION = {
        "name" => SNAPSHOT_TOOL,
        "description" =>
          "Replace the shared application state with a new snapshot; the " \
          "frontend re-renders from it. Send the COMPLETE next state object, " \
          "not a diff. Prefer AGUISendStateDelta for small targeted changes.",
        "parameters" => {
          "type" => "object",
          "properties" => {
            "snapshot" => {
              "type" => "object",
              "description" => "The complete new application state.",
            },
          },
          "required" => %w[snapshot],
        },
      }.freeze

      DELTA_DEFINITION = {
        "name" => DELTA_TOOL,
        "description" =>
          "Apply a JSON Patch (RFC 6902) to the shared application state — an " \
          "array of {op, path, value} operations. Use for small, targeted " \
          "changes. Paths are JSON Pointers, e.g. " \
          "\"/documentEditor/activeTabId\". ops: add, replace, remove, move, " \
          "copy, test.",
        "parameters" => {
          "type" => "object",
          "properties" => {
            "delta" => {
              "type" => "array",
              "description" =>
                "JSON Patch operations, e.g. " \
                "[{\"op\":\"replace\",\"path\":\"/theme\",\"value\":\"dark\"}].",
              "items" => { "type" => "object" },
            },
          },
          "required" => %w[delta],
        },
      }.freeze

      def initialize(app, state: nil)
        @app = app
        @initial_state = normalize(state)
      end

      def call(env)
        seed_state(env)
        advertise(env)

        before = env[:messages].length
        @app.call(env)

        # Only this iteration's assistant message — seeded history can carry
        # old state-tool turns that must not re-emit.
        appended = env[:messages][before..] || []
        assistant = appended.reverse.find { |m| m.respond_to?(:tool_call?) && m.tool_call? }
        if assistant
          apply_state_calls(env, assistant)
        end

        env
      end

      private

        def apply_state_calls(env, assistant)
          state_calls = assistant.tool_calls.select { |tc| TOOL_NAMES.include?(tc.name) }
          unless state_calls.empty?
            state_calls.each { |tool_call| handle(env, tool_call) }

            # State tools don't end the run — they're server-side, not browser
            # tools — so let Loop::ToolResult continue (last message is now
            # :tool). Only override the exit for a PURE state turn; a real
            # client tool mixed in still ends the run so the browser runs it.
            if assistant.tool_calls.all? { |tc| TOOL_NAMES.include?(tc.name) }
              env[:should_exit] = false
            end
          end
        end

        def seed_state(env)
          unless env.key?(:state)
            env[:state] = @initial_state
          end
        end

        # Idempotent — the turn loop re-enters every iteration.
        def advertise(env)
          env[:tools] ||= []
          names = env[:tools].map { |t| t.is_a?(Hash) ? t["name"] : nil }
          [SNAPSHOT_DEFINITION, DELTA_DEFINITION].each do |definition|
            unless names.include?(definition["name"])
              env[:tools] << definition
            end
          end
        end

        def handle(env, tool_call)
          case tool_call.name
          when SNAPSHOT_TOOL then apply_snapshot(env, tool_call)
          when DELTA_TOOL    then apply_delta(env, tool_call)
          end
        end

        def apply_snapshot(env, tool_call)
          snapshot = tool_call.arguments["snapshot"]
          if snapshot.is_a?(Hash)
            env[:state] = snapshot
            env[:events] << { type: :state_snapshot, data: { snapshot: snapshot } }
            ack(env, tool_call)
          else
            ack(env, tool_call, error: "snapshot must be an object")
          end
        end

        def apply_delta(env, tool_call)
          delta = tool_call.arguments["delta"]
          if delta.is_a?(Array)
            patch_state(env, tool_call, delta)
          else
            ack(env, tool_call, error: "delta must be an array of JSON Patch operations")
          end
        end

        # Keep our copy coherent for later reads/deltas; the frontend applies
        # the same patch to its own store. A bad patch is reported back to the
        # model as a tool error rather than raising the run.
        def patch_state(env, tool_call, delta)
          patched = Hana::Patch.new(delta).apply(deep_dup(env[:state] || {}))
        rescue StandardError => e
          ack(env, tool_call, error: "invalid JSON Patch: #{e.message}")
        else
          env[:state] = patched
          env[:events] << { type: :state_delta, data: { delta: delta } }
          ack(env, tool_call)
        end

        # Append the tool result (so the assistant tool-call has its matching
        # :tool message and Loop::ToolResult continues) and emit TOOL_CALL_RESULT
        # on the wire — the exact shape server tools produce.
        def ack(env, tool_call, error: nil)
          content = error ? { "status" => "error", "error" => error } : { "status" => "ok" }
          json = JSON.generate(content)
          env[:messages].tool(json, tool_call_id: tool_call.id)
          env[:events] << {
            type: :tool_call_result,
            data: {
              message_id: SecureRandom.uuid,
              tool_call_id: tool_call.id,
              content: json,
            },
          }
        end

        def normalize(state)
          if state.nil?
            nil
          elsif state.respond_to?(:to_h)
            state.to_h
          else
            state
          end
        end

        def deep_dup(obj)
          case obj
          when Hash  then obj.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
          when Array then obj.map { |v| deep_dup(v) }
          else obj
          end
        end
    end
  end
end

__END__

describe "AgUi::Middleware::State" do
  snapshot_call = ->(args) do
    Brute::Message.new(
      role: :assistant, content: nil,
      tool_calls: [{ id: "tc1", name: "AGUISendStateSnapshot", arguments: args }],
    )
  end

  delta_call = ->(args) do
    Brute::Message.new(
      role: :assistant, content: nil,
      tool_calls: [{ id: "tc1", name: "AGUISendStateDelta", arguments: args }],
    )
  end

  it "advertises both state tools idempotently and seeds env[:state] from input" do
    seen = nil
    mw = AgUi::Middleware::State.new(->(env) { seen = env }, state: { "theme" => "light" })
    env = { messages: Brute.log, events: [], tools: [{ "name" => "navigate" }] }
    mw.call(env)
    mw.call(env) # second loop iteration — no dupes

    seen[:tools].map { |t| t["name"] }.should ==
      %w[navigate AGUISendStateSnapshot AGUISendStateDelta]
    seen[:state].should == { "theme" => "light" }
  end

  it "seeds from a Definition-like state via to_h" do
    definition = Object.new
    def definition.to_h = { "count" => 1 }
    seen = nil
    AgUi::Middleware::State.new(->(env) { seen = env }, state: definition)
      .call({ messages: Brute.log, events: [], tools: [] })
    seen[:state].should == { "count" => 1 }
  end

  it "AGUISendStateSnapshot: sets state, emits STATE_SNAPSHOT + result, continues the run" do
    terminal = ->(env) { env[:messages] << snapshot_call.("snapshot" => { "count" => 3 }) }
    env = { messages: Brute.log, events: [], tools: [], should_exit: true }
    AgUi::Middleware::State.new(terminal).call(env)

    env[:state].should == { "count" => 3 }
    env[:events].map { |e| e[:type] }.should == %i[state_snapshot tool_call_result]
    env[:events][0][:data][:snapshot].should == { "count" => 3 }
    env[:messages].last.role.should == :tool
    env[:messages].last.tool_call_id.should == "tc1"
    env[:messages].last.content.should == "{\"status\":\"ok\"}"
    env[:should_exit].should == false
  end

  it "AGUISendStateDelta: patches state (Hana), emits STATE_DELTA with the raw ops" do
    delta = [{ "op" => "replace", "path" => "/theme", "value" => "dark" }]
    terminal = ->(env) { env[:messages] << delta_call.("delta" => delta) }
    env = { messages: Brute.log, events: [], tools: [], state: { "theme" => "light" }, should_exit: true }
    AgUi::Middleware::State.new(terminal).call(env)

    env[:state].should == { "theme" => "dark" }
    env[:events].map { |e| e[:type] }.should == %i[state_delta tool_call_result]
    env[:events][0][:data][:delta].should == delta
    env[:should_exit].should == false
  end

  it "adds a nested key via delta against seeded state" do
    delta = [{ "op" => "add", "path" => "/documentEditor", "value" => { "activeTabId" => "doc-2" } }]
    terminal = ->(env) { env[:messages] << delta_call.("delta" => delta) }
    env = { messages: Brute.log, events: [], tools: [], should_exit: true }
    AgUi::Middleware::State.new(terminal, state: { "documentEditor" => { "activeTabId" => "doc-1" } })
      .call(env)

    env[:state].should == { "documentEditor" => { "activeTabId" => "doc-2" } }
    env[:events][0][:type].should == :state_delta
  end

  it "reports a bad patch back to the model as a tool error, no STATE_DELTA emitted" do
    delta = [{ "op" => "replace", "path" => "/missing/deep", "value" => 1 }]
    terminal = ->(env) { env[:messages] << delta_call.("delta" => delta) }
    env = { messages: Brute.log, events: [], tools: [], state: {}, should_exit: true }
    AgUi::Middleware::State.new(terminal).call(env)

    env[:events].map { |e| e[:type] }.should == %i[tool_call_result]
    JSON.parse(env[:events][0][:data][:content])["status"].should == "error"
    env[:messages].last.role.should == :tool
  end

  it "rejects a non-array delta and a non-object snapshot as tool errors" do
    [delta_call.("delta" => "nope"), snapshot_call.("snapshot" => "nope")].each do |msg|
      terminal = ->(env) { env[:messages] << msg }
      env = { messages: Brute.log, events: [], tools: [] }
      AgUi::Middleware::State.new(terminal).call(env)
      JSON.parse(env[:events].last[:data][:content])["status"].should == "error"
    end
  end

  it "leaves should_exit set when a real client tool is mixed into the turn" do
    terminal = ->(env) do
      env[:messages] << Brute::Message.new(
        role: :assistant, content: nil,
        tool_calls: [
          { id: "tc1", name: "AGUISendStateSnapshot", arguments: { "snapshot" => { "a" => 1 } } },
          { id: "tc2", name: "navigate", arguments: { "path" => "/x" } },
        ],
      )
    end
    env = { messages: Brute.log, events: [], tools: [], should_exit: true }
    AgUi::Middleware::State.new(terminal).call(env)

    env[:events].any? { |e| e[:type] == :state_snapshot }.should == true
    env[:should_exit].should == true # browser still needs to run navigate
  end

  it "does nothing on a plain text turn" do
    env = { messages: Brute.log, events: [], tools: [] }
    AgUi::Middleware::State.new(->(e) { e[:messages].assistant("hi") }).call(env)
    env[:events].should == []
    env.key?(:should_exit).should == false
  end
end
