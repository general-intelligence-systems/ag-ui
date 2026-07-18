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

# A standard Brute agent, driven inside the AG-UI run handler (open the SSE
# stream, RUN_STARTED → turn → RUN_FINISHED, RUN_ERROR on failure).
BARE_AGENT = AgUi.agent(agent_id: "default") do |env|
  input = env["ag_ui.input"]

  agent = Brute.agent
               .use(AgUi::Middleware::SystemPrompt,
                    prompt: "You are a helpful assistant. Answer concisely.",
                    context: input.context)
               .use(AgUi::Middleware::ForwardedProps, props: input.forwarded_props)
               .use(Brute::Middleware::Loop::ToolResult)
               .use(Brute::Middleware::MaxIterations, max_iterations: 10)
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
    BARE_AGENT.call(env)
  end
end
