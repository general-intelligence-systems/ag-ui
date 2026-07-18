# frozen_string_literal: true

# Minimal echo agent for transport smoke-testing, served with ratalada:
#
#   bundle exec ruby examples/echo.rb          # listens on 127.0.0.1:9292
#
#   curl -s http://127.0.0.1:9292/api/copilotkit/info | jq
#   curl -sN -X POST http://127.0.0.1:9292/api/copilotkit/agent/default/run \
#     -H 'content-type: application/json' \
#     -d '{"threadId":"t1","runId":"r1","state":null,"messages":[{"id":"u1","role":"user","content":"hello"}],"tools":[],"context":[],"forwardedProps":null}'

require "ratalada/falcon"
require_relative "../lib/ag_ui"

ECHO_AGENT = AgUi.agent(agent_id: "default") do |env|
  input = env["ag_ui.input"]

  env["ag_ui.stream"].open(thread_id: input.thread_id, run_id: input.run_id) do |s|
    s.run_started

    last_user = input.messages.reverse.find { |m| m["role"] == "user" }
    text = last_user ? last_user["content"].to_s : "(no user message)"
    message_id = "echo-#{input.run_id}"

    s.text_message_start(message_id: message_id)
    text.chars.each_slice(8) do |chunk|
      s.text_message_content(message_id: message_id, delta: chunk.join)
      sleep 0.02
    end
    s.text_message_end(message_id: message_id)

    s.run_finished
  end
end

# Triage suffix-matches, so the /api/copilotkit prefix needs no mount map.
Server.run do |request|
  case request
  in { env: }
    ECHO_AGENT.call(env)
  end
end
