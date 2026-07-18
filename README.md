# ag-ui

A Ruby server implementation of the **[AG-UI protocol](https://github.com/ag-ui-protocol/ag-ui)** —
plus the CopilotKit runtime surface its React client expects — so you can
drive a CopilotKit frontend from Ruby (Falcon/Rails) with any LLM.

```ruby
require "ag_ui"
require "ag_ui/terminals/ruby_llm"

RubyLLM.configure { |c| c.anthropic_api_key = ENV.fetch("ANTHROPIC_API_KEY") }

run_loop = AgUi::RunLoop.new(
  system_prompt: "You are a helpful assistant.",
  &AgUi::Terminals::RubyLLM.new(model: "anthropic/claude-sonnet-4-5")
)

# A Rack app serving /info, /agent/:id/run (SSE), /connect, /stop —
# mount it wherever the client's runtimeUrl points.
run AgUi.agent(agent_id: "default", &run_loop)
```

## What you get

- **Schema-exact wire protocol** — every event/type definition is *generated*
  from the reference Python SDK's models (`data/generate-ag-ui-schema.py`),
  validated with json_schemer before it hits the wire, and conformance-tested
  byte-for-byte against the official SDK test expectations.
- **Falcon-native SSE streaming** — `Protocol::HTTP::Body::Writable` bodies
  with Async fibers: true streaming with backpressure, no buffering.
- **The CopilotKit runtime surface** — `GET /info` (capability envelope),
  `POST /agent/:id/run`, `/connect` (replay + live attach), `/stop`
  (run cancellation), and the bare-run root `HttpAgent` expects.
- **The client-tool multi-run model** — frontend tools (`useFrontendTool`,
  `useHumanInTheLoop`) are advertised schema-only, emitted as `TOOL_CALL_*`,
  and the run ends cleanly for the browser to execute and re-run.
- **Server tools with an agentic turn loop** — `{name:, description:,
  parameters:, handler:}` tools execute inline and the model continues the
  same run (brute's `Loop::ToolResult` + `MaxIterations`).
- **A2UI generative UI** — `render_a2ui` injection, catalog fetch with
  retry/degrade, the tool-call → `ACTIVITY_SNAPSHOT` transform, semantic
  component validation (a port of the official `a2ui_toolkit`), and in-run
  regeneration on invalid surfaces.
- **Extended thinking → `REASONING_*`**, multimodal attachments, context
  injection, and dynamic suggestions (`forwardedProps.toolChoice`).
- **LLM-agnostic core** — the LLM lives in a terminal callable at the bottom
  of a [brute](https://rubygems.org/gems/brute) middleware pipeline; a
  [ruby_llm](https://github.com/crmne/ruby_llm) terminal ships as the
  reference adapter (`require "ag_ui/terminals/ruby_llm"`).

## Installation

```bash
bundle add ag-ui
```

The gem requires Ruby ≥ 3.3. The reference terminal additionally needs
`ruby_llm`; the server runs on any Rack 3 host, with Falcon recommended for
native streaming.

## Architecture

```
HTTP/SSE   Triage → SSEStream → dispatch          (Rack, Falcon-native)
turn       SystemPrompt → ForwardedProps →
           Loop::ToolResult → MaxIterations →
           A2ui → ToolRouter → terminal           (brute pipeline)
terminal   your LLM call                          (ruby_llm adapter included)
```

One run = one `RunAgentInput` POST. The pipeline seeds the conversation from
the request (history, tools, context), streams events through an
`EventBridge` into the SSE body as they happen, and ends the run per the
AG-UI contract (`RUN_FINISHED` / `RUN_ERROR`). A pluggable `RunStore`
(in-memory included) records every run for `/connect` replay, live
mid-run attach, and `/stop` cancellation.

## Examples

Runnable servers in [`examples/`](examples/) (served with
[ratalada](https://rubygems.org/gems/ratalada)):

- `echo.rb` — transport smoke test, no LLM
- `claude.rb` — full runtime surface: Claude streaming, a demo server tool,
  optional extended thinking (`THINKING_BUDGET=2048`)
- `bare.rb` — the bare `HttpAgent` endpoint shape
- `a2ui_analyst.rb` — A2UI agent for the vendored showcase canvas

## Verification

Beyond the unit + conformance suite (`bin/test`), the repo vendors two real
CopilotKit apps as browser-driven regression harnesses — see
[`verification/README.md`](verification/README.md) for the runbook: chat,
frontend tools, human-in-the-loop, and an A2UI canvas, all driven against
this server with the Node runtime both in and out of the path.

## Development

```bash
bin/setup        # bundle install (nix users: `nix develop` provides the shell)
bin/test         # scampi — specs are co-located in each file's __END__ block
bin/console      # irb with the gem loaded
```

Releasing:

```bash
bin/increment-version <major|minor|patch>
bin/tag-version
bin/release-gem
```

## License

MIT — see [LICENSE](LICENSE).
