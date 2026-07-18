# frozen_string_literal: true

# Shared state (CoAgents): the agent reads the frontend's state and writes it
# back with STATE_SNAPSHOT / STATE_DELTA, served with ratalada:
#
#   ANTHROPIC_API_KEY=sk-... bundle exec ruby examples/shared_state.rb
#
# Ask it to replace the whole state:
#   curl -sN -X POST http://127.0.0.1:9292/api/copilotkit/agent/default/run \
#     -H 'content-type: application/json' \
#     -d '{"threadId":"t1","runId":"r1","state":{"recipe":{"title":"Old"}},
#          "messages":[{"id":"u1","role":"user",
#            "content":"Set the recipe title to Spicy Tacos and add a step: fry the shells."}],
#          "tools":[],"context":[],"forwardedProps":null}'
#
# You should see STATE_SNAPSHOT / STATE_DELTA frames, then a text confirmation.

require "ratalada/falcon"
require_relative "../lib/ag_ui"
require_relative "../lib/ag_ui/terminals/ruby_llm"

RubyLLM.configure do |config|
  config.anthropic_api_key = ENV.fetch("ANTHROPIC_API_KEY")
end

terminal = AgUi::Terminals::RubyLLM.new(
  model: ENV.fetch("COPILOTKIT_MODEL", "anthropic/claude-sonnet-4-5"),
)

SYSTEM_PROMPT = <<~PROMPT.strip
  You keep a shared application state in sync with the user's UI.

  - The CURRENT state is given to you as context. Read it before deciding.
  - To change it, CALL a tool: AGUISendStateDelta for small targeted edits
    (preferred), or AGUISendStateSnapshot to replace the whole object.
  - After the tool result comes back, confirm what you changed in one sentence.
    Never claim you changed the UI unless you actually called a state tool.
PROMPT

# The agent: State sits OUTSIDE ToolRouter so ToolRouter streams the tool-call
# chrome while State owns the STATE_* channel and lets the run continue.
SHARED_STATE_AGENT = AgUi.agent(agent_id: "default") do |env|
  input = env["ag_ui.input"]

  # Surface the inbound state to the model as context so it can READ what the
  # UI currently shows (the app decides how much to expose — here, all of it).
  context = Array(input.context) + [
    {
      "description" => "Current shared application state (JSON)",
      "value" => JSON.generate(input.state || {}),
    },
  ]

  agent = Brute.agent
               .use(AgUi::Middleware::SystemPrompt, prompt: SYSTEM_PROMPT, context: context)
               .use(AgUi::Middleware::ForwardedProps, props: input.forwarded_props)
               .use(Brute::Middleware::Loop::ToolResult)
               .use(Brute::Middleware::MaxIterations, max_iterations: 10)
               .use(AgUi::Middleware::State, state: input.state)
               .use(AgUi::Middleware::ToolRouter, tools: input.tools)
               .run(terminal)

  env["ag_ui.stream"].open(thread_id: input.thread_id, run_id: input.run_id) do |stream|
    stream.run_started
    agent.start(AgUi::Messages.to_brute(input.messages), events: AgUi::EventBridge.new(stream))
    stream.run_finished
  rescue => e
    stream.run_error(message: e.message, code: e.class.name)
  end
end

Server.run do |request|
  case request
  in { env: }
    SHARED_STATE_AGENT.call(env)
  end
end
