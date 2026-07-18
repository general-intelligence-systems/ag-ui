# frozen_string_literal: true

# A2UI-enabled agent: Claude + render_a2ui with an inline demo catalog.
#
#   ANTHROPIC_API_KEY=sk-... bundle exec ruby examples/a2ui.rb
#
#   curl -s http://127.0.0.1:9292/api/copilotkit/info | jq .a2uiEnabled
#   curl -sN -X POST http://127.0.0.1:9292/api/copilotkit/agent/default/run \
#     -H 'content-type: application/json' \
#     -d '{"threadId":"t1","runId":"r1","state":null,"messages":[{"id":"u1","role":"user","content":"Render a card titled Hello Moon with a short tagline."}],"tools":[],"context":[],"forwardedProps":null}'

require "ratalada/falcon"
require_relative "../lib/ag_ui"
require_relative "../lib/ag_ui/terminals/ruby_llm"

RubyLLM.configure do |config|
  config.anthropic_api_key = ENV.fetch("ANTHROPIC_API_KEY")
end

CATALOG = AgUi::A2ui::Catalog.new(
  catalog_id: "example://demo-catalog",
  components: {
    "Card" => {
      "description" => "A titled card container",
      "props" => {
        "title" => { "type" => "string" },
        "children" => { "type" => "array" },
      },
    },
    "Text" => {
      "description" => "A paragraph of text",
      "props" => { "text" => { "type" => "string" } },
    },
  },
)

terminal = AgUi::Terminals::RubyLLM.new(
  model: ENV.fetch("COPILOTKIT_MODEL", "anthropic/claude-sonnet-4-5"),
)

# A standard Brute agent with the A2UI middleware (injects render_a2ui + turns
# its calls into ACTIVITY_SNAPSHOT against CATALOG). Driven inside the AG-UI run
# handler (open stream, RUN_STARTED → turn → RUN_FINISHED, RUN_ERROR).
A2UI_AGENT = AgUi.agent(agent_id: "default", a2ui_enabled: true) do |env|
  input = env["ag_ui.input"]

  agent = Brute.agent
               .use(AgUi::Middleware::SystemPrompt,
                    prompt: "You are a helpful assistant. When asked to render or show UI, " \
                            "use the render_a2ui tool with the components from the catalog.",
                    context: input.context)
               .use(AgUi::Middleware::ForwardedProps, props: input.forwarded_props)
               .use(Brute::Middleware::Loop::ToolResult)
               .use(Brute::Middleware::MaxIterations, max_iterations: 10)
               .use(AgUi::Middleware::A2ui, catalog: CATALOG)
               .use(AgUi::Middleware::ToolRouter, tools: input.tools, server_tools: [])
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
    A2UI_AGENT.call(env)
  end
end
