# frozen_string_literal: true

# Ruby replacement for the a2ui-pdf-analyst showcase's Python agent
# (verification/a2ui-pdf-analyst): serves both /fixed and /dynamic
# HttpAgent URLs with one Claude-backed A2UI agent. The catalog id and
# component vocabulary are extracted from the vendored agent source —
# nothing transcribed by hand.
#
#   ANTHROPIC_API_KEY=sk-... PORT=8123 bundle exec ruby examples/a2ui_analyst.rb
#
#   cd verification/a2ui-pdf-analyst && npm run dev:web
#   open http://localhost:3000/dynamic — ask for any UI.

require "ratalada/falcon"
require_relative "../lib/ag_ui"
require_relative "../lib/ag_ui/terminals/ruby_llm"

RubyLLM.configure do |config|
  config.anthropic_api_key = ENV.fetch("ANTHROPIC_API_KEY")
end

catalog_py = File.read(
  File.expand_path("../verification/a2ui-pdf-analyst/agent/src/catalog.py", __dir__),
)
CATALOG_ID = catalog_py[/^CATALOG_ID = "([^"]+)"/, 1] or raise "CATALOG_ID not found"
CATALOG_PROMPT = catalog_py[/CATALOG_PROMPT = """\\?\n(.*?)"""/m, 1] or raise "CATALOG_PROMPT not found"

# Component names extracted from the vendored vocabulary ("- **Name** {...}"
# lines) so the toolkit validator enforces catalog membership — a surface
# using an invented component fails server-side instead of rendering
# "Unknown component" on the canvas.
CATALOG_COMPONENTS = CATALOG_PROMPT.scan(/^- \*\*(\w+)\*\*/).flatten.to_h { |name| [name, {}] }
if CATALOG_COMPONENTS.empty?
  raise "no components extracted from CATALOG_PROMPT"
end

SYSTEM_PROMPT = <<~PROMPT
  You are a UI-generation assistant. When the user asks for any UI — a
  dashboard, form, list, cards, charts — call the `render_a2ui` tool.

  ## Use THIS catalog:
  catalogId: #{CATALOG_ID}

  #{CATALOG_PROMPT}

  Design surfaces using ONLY components from the catalog above. Inline all
  data (plain values, not {path} bindings, unless a property explicitly
  accepts a path). Exactly one component must have id "root". Answer in
  plain text when no UI is needed.
PROMPT

terminal = AgUi::Terminals::RubyLLM.new(
  model: ENV.fetch("COPILOTKIT_MODEL", "anthropic/claude-sonnet-4-5"),
)

CATALOG = AgUi::A2ui::Catalog.new(catalog_id: CATALOG_ID, components: CATALOG_COMPONENTS)

# A standard Brute agent with the A2UI middleware. Driven inside the AG-UI run
# handler (open stream, RUN_STARTED → turn → RUN_FINISHED, RUN_ERROR).
ANALYST_AGENT = AgUi.agent(agent_id: "default", a2ui_enabled: true) do |env|
  input = env["ag_ui.input"]

  agent = Brute.agent
               .use(AgUi::Middleware::SystemPrompt, prompt: SYSTEM_PROMPT, context: input.context)
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

# The showcase points HttpAgents at :8123/fixed and :8123/dynamic — both
# rewrite to the bare-run root of the same agent.
Server.run do |request|
  case request
  in { verb: "POST", path: "/fixed" | "/dynamic", env: }
    ANALYST_AGENT.call(env.merge("PATH_INFO" => "/"))
  in { env: }
    ANALYST_AGENT.call(env)
  end
end
