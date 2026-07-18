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

run_loop = AgUi::RunLoop.new(
  system_prompt: "You are a helpful assistant. When asked to render or show UI, " \
                 "use the render_a2ui tool with the components from the catalog.",
  a2ui: CATALOG,
  &terminal
)

A2UI_AGENT = AgUi.agent(agent_id: "default", a2ui_enabled: true, &run_loop)

Server.run do |request|
  case request
  in { env: }
    A2UI_AGENT.call(env)
  end
end
