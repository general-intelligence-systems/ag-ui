# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project adheres to
[Semantic Versioning](https://semver.org/) (pre-1.0: minor versions may carry
breaking changes).

## [0.2.0]

### Removed

- **`AgUi::RunLoop`** (breaking). The AG-UI agent is no longer wrapped in a
  bespoke class. Compose it as a standard Brute agent at the call site — a
  `Brute.agent.use(...).run(terminal)` pipeline driven inside the `AgUi.agent`
  run handler (open the SSE stream → `RUN_STARTED` → `.start` → `RUN_FINISHED`,
  `RUN_ERROR` on failure). The middleware order and run lifecycle are now
  explicit at every call site instead of hidden in the class.

### Changed

- Ported the README, every file under `examples/`, and the ruby_llm terminal
  test to the standard-Brute-agent pattern.

### Migration

Replace:

```ruby
run_loop = AgUi::RunLoop.new(
  system_prompt: PROMPT, a2ui: catalog, server_tools: tools, &terminal
)
app = AgUi.agent(agent_id: "default", a2ui_enabled: true, &run_loop)
```

with:

```ruby
app = AgUi.agent(agent_id: "default", a2ui_enabled: true) do |env|
  input = env["ag_ui.input"]

  agent = Brute.agent
               .use(AgUi::Middleware::SystemPrompt, prompt: PROMPT, context: input.context)
               .use(AgUi::Middleware::ForwardedProps, props: input.forwarded_props)
               .use(Brute::Middleware::Loop::ToolResult)
               .use(Brute::Middleware::MaxIterations, max_iterations: 10)
               .use(AgUi::Middleware::A2ui, catalog: catalog) # a2ui only
               .use(AgUi::Middleware::ToolRouter, tools: input.tools, server_tools: tools)
               .run(terminal)

  env["ag_ui.stream"].open(thread_id: input.thread_id, run_id: input.run_id) do |stream|
    stream.run_started
    agent.start(AgUi::Messages.to_brute(input.messages), events: AgUi::EventBridge.new(stream))
    stream.run_finished
  rescue => e
    stream.run_error(message: e.message, code: e.class.name)
  end
end
```

## [0.1.0]

- Initial release: AG-UI protocol server + CopilotKit runtime surface
  (`/info`, `/agent/:id/run`, `/connect`, `/stop`), schema-exact wire protocol,
  Falcon-native SSE streaming, client-tool multi-run model, server tools, A2UI
  generative UI, reasoning, attachments, context, and suggestions.
