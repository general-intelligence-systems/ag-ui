# frozen_string_literal: true

# Bare AG-UI agent endpoint — the shape @ag-ui/client's HttpAgent expects
# when a CopilotKit runtime is configured with
# `new HttpAgent({ url: "http://127.0.0.1:9393/" })`. Used for the
# verification harness Swap A (replace a Python agent behind the Node
# runtime with this server).
#
#   ANTHROPIC_API_KEY=sk-... PORT=9393 bundle exec ruby examples/bare.rb
#
#   curl -sN -X POST http://127.0.0.1:9393/ \
#     -H 'content-type: application/json' \
#     -d '{"threadId":"t1","runId":"r1","state":null,"messages":[{"id":"u1","role":"user","content":"hi"}],"tools":[],"context":[],"forwardedProps":null}'

require "ratalada/falcon"
require_relative "../lib/ag_ui"
require_relative "../lib/ag_ui/terminals/ruby_llm"

RubyLLM.configure do |config|
  config.anthropic_api_key = ENV.fetch("ANTHROPIC_API_KEY")
end

terminal = AgUi::Terminals::RubyLLM.new(
  model: ENV.fetch("COPILOTKIT_MODEL", "anthropic/claude-sonnet-4-5"),
)

run_loop = AgUi::RunLoop.new(
  system_prompt: "You are a helpful assistant. Answer concisely.",
  &terminal
)

BARE_AGENT = AgUi.agent(agent_id: "default", &run_loop)

Server.run do |request|
  case request
  in { env: }
    BARE_AGENT.call(env)
  end
end
