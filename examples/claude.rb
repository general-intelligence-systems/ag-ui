# frozen_string_literal: true

# The real thing: Claude streaming through the AG-UI pipeline, served
# with ratalada:
#
#   ANTHROPIC_API_KEY=sk-... bundle exec ruby examples/claude.rb
#
#   curl -sN -X POST http://127.0.0.1:9292/api/copilotkit/agent/default/run \
#     -H 'content-type: application/json' \
#     -d '{"threadId":"t1","runId":"r1","state":null,"messages":[{"id":"u1","role":"user","content":"Say hello in exactly five words."}],"tools":[],"context":[],"forwardedProps":null}'

require "ratalada/falcon"
require_relative "../lib/ag_ui"
require_relative "../lib/ag_ui/terminals/ruby_llm"

RubyLLM.configure do |config|
  config.anthropic_api_key = ENV.fetch("ANTHROPIC_API_KEY")
end

# THINKING_BUDGET=2048 enables extended thinking -> REASONING_* events.
thinking_budget = ENV["THINKING_BUDGET"]

terminal = AgUi::Terminals::RubyLLM.new(
  model: ENV.fetch("COPILOTKIT_MODEL", "anthropic/claude-sonnet-4-5"),
  thinking: thinking_budget ? { budget: Integer(thinking_budget, 10) } : nil,
)

# A demo SERVER tool — executes inline; the model continues the same run
# with the result (Loop::ToolResult).
WEATHER = {
  name: "get_weather",
  description: "Get the current weather for a city. Call this whenever the " \
               "user asks about weather.",
  parameters: {
    "type" => "object",
    "properties" => { "city" => { "type" => "string" } },
    "required" => ["city"],
  },
  handler: ->(args) { { "city" => args["city"], "conditions" => "sunny", "temp_c" => 21 } },
}.freeze

run_loop = AgUi::RunLoop.new(
  system_prompt: "You are a helpful assistant. Answer concisely.",
  server_tools: [WEATHER],
  &terminal
)

CLAUDE_AGENT = AgUi.agent(agent_id: "default", &run_loop)

Server.run do |request|
  case request
  in { env: }
    CLAUDE_AGENT.call(env)
  end
end
