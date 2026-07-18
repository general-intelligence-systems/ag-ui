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

# A standard Brute agent with one SERVER tool (WEATHER) — the ToolRouter runs
# it inline and Loop::ToolResult continues the same run. Driven inside the AG-UI
# run handler (open stream, RUN_STARTED → turn → RUN_FINISHED, RUN_ERROR).
CLAUDE_AGENT = AgUi.agent(agent_id: "default") do |env|
  input = env["ag_ui.input"]

  agent = Brute.agent
               .use(AgUi::Middleware::SystemPrompt,
                    prompt: "You are a helpful assistant. Answer concisely.",
                    context: input.context)
               .use(AgUi::Middleware::ForwardedProps, props: input.forwarded_props)
               .use(Brute::Middleware::Loop::ToolResult)
               .use(Brute::Middleware::MaxIterations, max_iterations: 10)
               .use(AgUi::Middleware::ToolRouter, tools: input.tools, server_tools: [WEATHER])
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
    CLAUDE_AGENT.call(env)
  end
end
