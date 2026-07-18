# ag-ui (Ruby)

A Ruby implementation of the **AG-UI protocol** server + the parts of the
**CopilotKit runtime** we depend on — so we can retire the Node
`sidecars/copilotkit` process and drive our existing CopilotKit **frontend** from
Ruby (Falcon/Rails), backed by [`ruby_llm`](https://github.com/crmne/ruby_llm).

## Why this is smaller than it sounds

AG-UI is "just another SSE agent protocol." We already shipped one in Ruby:
`~/brute/a2a` (Agent2Agent). Its transport substrate is protocol-agnostic and
**directly reusable**:

- Falcon-native SSE via Async fibers (`env["…stream"].open do |s| … end`)
- Rack::Builder middleware pipeline + operation triage
- typed, schema-validated event emitters
- Rails/Rack mounting, schema validation, test helpers

So this project is **"port the a2a transport patterns + add the AG-UI event
vocabulary + a `ruby_llm` run loop"** — not a greenfield runtime.

## The two layers, kept separate

- **`ruby_llm`** = the LLM engine (Anthropic streaming, tool schemas, extended
  thinking, structured output). It does "call the provider and stream."
- **`ag-ui` (this gem)** = the protocol. It does "speak AG-UI to the browser":
  parse `RunAgentInput`, run the loop, translate `ruby_llm` chunks into AG-UI
  events, and manage the client-side tool round-trip.

We **intercept** `ruby_llm`'s tool loop rather than letting it auto-execute —
because most of our tools run in the browser, not the server (see
[03-run-loop-and-tools](docs/03-run-loop-and-tools.md)).

## What we're replacing

The Node worker (`sidecars/copilotkit/server.mjs`): `CopilotRuntime` +
`BuiltInAgent` + `InMemoryAgentRunner` + A2UI middleware, served over
`createCopilotHonoHandler` at `/api/copilotkit`. The frontend talks to it with
`useAgent` / `useCopilotKit` / `useFrontendTool` / `useHumanInTheLoop` / A2UI /
suggestions. The full inventory the gem must satisfy is in
[06-current-usage-to-replace](docs/06-current-usage-to-replace.md).

## Docs

1. [Reference material](docs/01-reference-material.md) — the JS libraries/files that are the source of truth.
2. [Protocol](docs/02-protocol.md) — endpoints, SSE framing, `RunAgentInput`, the event vocabulary.
3. [Run loop & tools](docs/03-run-loop-and-tools.md) — the loop over `ruby_llm`; server vs client tools; the multi-run model; HITL.
4. [A2UI](docs/04-a2ui.md) — the `render_a2ui` tool + activity-surface events + catalog.
5. [Suggestions, context, attachments](docs/05-suggestions-context-attachments.md) — the "extra" client features.
6. [Current usage to replace](docs/06-current-usage-to-replace.md) — exhaustive inventory of what this project uses, mapped to protocol requirements.
7. [Gem design & plan](docs/07-gem-design-and-plan.md) — reuse map from a2a, module layout, phased build, conformance harness.

## Golden rule

**Wire fidelity is the whole game.** Every event's JSON must match `@ag-ui/core`
exactly and `/info` must advertise what the provider expects, or the frontend
fails *silently*. Port the `@ag-ui/core` schemas into validation and test each
phase against the **live headless panel** before moving on.
