# 08 — Plan of attack (checklist)

Built after verifying the plan against a fresh clone of
`github.com/ag-ui-protocol/ag-ui` (`/tmp/ag-ui`, main @ `3a7433e`, 2026-07-17)
and researching the **brute** gem (`~/brute/brute`) middleware pattern.

## Verified wire facts (the plan's "(confirm)" items — now confirmed)

From `sdks/python/ag_ui/encoder/encoder.py` + `core/{events,types,capabilities}.py`,
cross-checked against `sdks/typescript/packages/core/src/events.ts`:

- **SSE framing**: `data: <json>\n\n` per event. **No `event:` line, no `id:`,
  no heartbeat** in the reference encoder. `Content-Type: text/event-stream`.
  JSON is **camelCase** (pydantic `by_alias`) with **null fields omitted**
  (`exclude_none`). A protobuf media type exists
  (`application/vnd.ag-ui.event+proto`) — ignore it, SSE only.
- **`ACTIVITY_SNAPSHOT` is FLAT** — doc 04's sketch was wrong (now corrected):
  `{ "type":"ACTIVITY_SNAPSHOT", "messageId", "activityType", "content", "replace" (default true) }`.
  No `activity:` wrapper. (`ACTIVITY_DELTA` = `{messageId, activityType, patch}`,
  JSON Patch.) The **history** form is the `ActivityMessage`:
  `{ id, role:"activity", activityType, content }`.
- **`RunAgentInput`**: `threadId, runId, parentRunId?, state, messages, tools,
  context, forwardedProps, resume?`. `context` is `[{description, value}]`.
- **Messages**: `AssistantMessage.toolCalls` is OpenAI-shaped
  `[{id, type:"function", function:{name, arguments:<string>}}]`.
  `ToolMessage` = `{id, role:"tool", content:<string>, toolCallId, error?}`.
  `UserMessage.content` = string **or** `InputContent[]` where parts are
  `text | image | audio | video | document`, each media part carrying
  `source: {type:"data"|"url", value, mimeType}` (old `binary` part deprecated).
- **HITL = plain multi-run**, confirmed by `human_in_the_loop.py`: emit
  `TOOL_CALL_START/ARGS/END` then a **plain** `RUN_FINISHED` (no result, no
  outcome); on the next run, "last message is `role:"tool"`" ⇒ continue.
  A newer **interrupt protocol** exists (`RUN_FINISHED.outcome =
  {type:"interrupt", interrupts:[…]}` + `RunAgentInput.resume[]`) — **not
  needed** for CopilotKit `useHumanInTheLoop`; stay on the classic round-trip.
- **Capabilities object** (`core/capabilities.py`): all-optional categories
  `identity, transport, tools, output, state, multiAgent, reasoning,
  multimodal, execution, humanInTheLoop, custom`. NOTE: this is the
  *capabilities* half only — the exact `/info` envelope (incl. `agents` list and
  the a2ui advertisement) is CopilotKit-runtime-specific and still must be read
  from `@copilotkit/runtime` in the host app's `node_modules` (checklist item below).
- Both `THINKING_*` and `REASONING_*` exist in the enum; emit `REASONING_*`
  (matches `ReasoningMessage`, `role:"reasoning"`), never `THINKING_*`.

## Architecture decision: brute's turn pipeline for the run loop

The **brute** gem (`~/brute/brute`) is a Rack-style middleware framework for
LLM agent turns: an `env` hash (`:messages`, `:tools`, `:events`,
`:current_iteration`…) flows through `Rack::Builder`-composed middleware to a
terminal `run` proc that calls the LLM. Zero LLM dependencies; `rack ~3.0`,
`async ~2.0` — same substrate as a2a/Falcon.

Why it's ideal for our tool-call handling — the three mechanisms map 1:1:

| AG-UI need | brute mechanism |
|---|---|
| client tool ⇒ end the run, no result | **short-circuit**: middleware returns `env` without further looping (cf. `MaxIterations`, `env[:should_exit]`) |
| server tool ⇒ execute inline, loop | `ToolPipeline` (`lib/brute/middleware/070_tool_pipeline.rb`) executes on the way *out*, appends results; `Loop::ToolResult` (`006_loop.rb`) re-invokes the stack while last message is `role: :tool` |
| stream AG-UI events mid-turn | `env[:events]` sink — inject a sink that translates to SSE emitters (`s.tool_call_start`…) |

So the layering becomes:

```
a2a substrate  → HTTP/SSE transport middleware (Rack request → SSE stream)
brute substrate → turn middleware (env → LLM → tools → loop)
ag-ui           → the AG-UI vocabulary + the glue between the two
```

Target run-loop shape (inside the a2a-style `env["ag_ui.stream"].open`):

```ruby
pipeline = Brute.agent
  .use AgUi::Middleware::EventBridge, stream: s        # env[:events] → SSE emitters
  .use AgUi::Middleware::SystemPrompt, prompt: HOST_SYSTEM_PROMPT
  .use AgUi::Middleware::ContextInjection              # RunAgentInput.context → addendum
  .use Brute::Middleware::Loop::ToolResult             # loop while server-tool results
  .use Brute::Middleware::MaxIterations
  .use AgUi::Middleware::A2ui, catalog: catalog        # inject render_a2ui; calls → ACTIVITY_SNAPSHOT
  .use AgUi::Middleware::ToolRouter, server_tools: registry
       #  client tool → emit TOOL_CALL_*, set env[:should_exit] (run ends)
       #  server tool → execute, emit TOOL_CALL_RESULT, append tool msg (loop continues)
  .run ->(env) { <ruby_llm streaming call; deltas → env[:events]; append messages> }
```

Open decision (resolve in Phase 0): **depend on the brute gem** vs **vendor the
pattern** (Pipeline/Chainable is ~40 lines; ToolPipeline/Loop are the value).
Default: depend on `brute` — same author, same stack, and we inherit
`Loop::ToolResult`, `MaxIterations`, OTel middleware, and session-log for free.

---

## The checklist

### Phase 0 — Ground truth & scaffolding
- [x] Clone `ag-ui-protocol/ag-ui` → `/tmp/ag-ui` (main @ `3a7433e`)
- [x] Confirm SSE framing, event shapes, `RunAgentInput`, capabilities (above)
- [x] Correct doc 04's `ACTIVITY_SNAPSHOT` sketch to the flat shape
- [x] Read the **`copilotkit-agui` skill** in the host-app repo → rules captured
      in [09](09-ground-truth-host-app.md) §7
- [x] Read `@copilotkit/runtime/dist` in host-app → `/info` envelope, full route
      table (incl. the previously-unknown **stop** route), SSE headers, plain
      `RUN_FINISHED` after client tools all confirmed — [09](09-ground-truth-host-app.md) §1–4
- [x] Read `@ag-ui/a2ui-middleware` in host-app → static `render_a2ui` schema,
      catalog-via-context, transform + dedup + synthetic tool result —
      [09](09-ground-truth-host-app.md) §6
- [x] Decide: **depend on `brute`** (vendoring rejected) — [09](09-ground-truth-host-app.md) §8
- [x] Scaffold gem: `ag_ui.gemspec` (rack/async/json_schemer/brute; ruby_llm as
      dev dep — loop stays LLM-agnostic), flake.nix dev shell, scampi inline
      specs (house style), `EventEncoder` ported + 4 specs green

### Phase 1 — Transport + streaming text  *(gate: panel streams a reply)*
- [x] Port a2a's `SSE::Stream` + `Middleware::SSEStream` → `AgUi::Server::SSE`
      with the AG-UI `EventEncoder` framing — verified over real Falcon HTTP
- [x] Typed emitters + JSON-Schema validation — for the ENTIRE vocabulary
      (generated from `data/ag_ui.json`, itself generated from the Python SDK
      pydantic models — 74 definitions, no hand transcription); pydantic
      non-null defaults filled, nulls omitted, `type` leads each frame
- [x] `AgUi::RunInput`: raw-hash validation (explicit nulls survive) +
      Definition wrapper; multimodal content + extra fields tolerated
- [x] Routes live as `AgUi.agent {}` Rack app (Triage → SSEStream → handler):
      `/info` (doc-09 envelope), `/run` (SSE), `/connect` (immediate-close
      stub), `/stop` (ack; task-cancel lands with the run loop), 400/404/
      OPTIONS — all smoke-tested with `curl -N` (`examples/echo.ru`)
- [x] Terminal proc over `ruby_llm` (`AgUi::Terminals::RubyLLM`, lazily
      required): verified LIVE — claude-sonnet-4-5 deltas streamed through
      Falcon end to end (2.4s), multi-turn history recall + context addendum
      confirmed (`examples/claude.ru`)
- [x] Brute pipeline skeleton: the AG-UI run handler (RUN_STARTED → a standard
      `Brute.agent` turn → RUN_FINISHED/RUN_ERROR) + `EventBridge` (env[:events] → SSE, live) +
      `Messages.to_brute` (toolCalls round-trip) + `Middleware::SystemPrompt`
      (prompt + context addendum). NOTE: Gemfile path-pins brute to the
      sibling checkout — published 3.0.0 predates Brute::Message
- [ ] Conformance: `curl -N` diff Ruby vs the Python `server-starter`
      (`agentic_chat.py`) for the same input; then live panel
      (`runtimeUrl` → Ruby) streams a message
- [ ] `AgUi::TestHelpers` (a2a pattern): drive `/run` over real Falcon, assert
      event sequences

### Phase 2 — Client tools, multi-run  *(gate: `navigate` + `queryDataModel` work)*
- [x] Emitters + schemas: `TOOL_CALL_START/ARGS/END` (+ `TOOL_CALL_RESULT` for later)
- [x] `RunAgentInput.tools` → schema-only `ClientTool`s (`RubyLLM::Tool`
      subclass whose `call` **halts** — never executes server-side)
- [x] `AgUi::Middleware::ToolRouter`: emits `TOOL_CALL_*`, sets
      `env[:should_exit]` ⇒ plain `RUN_FINISHED` — live-verified vs real
      Claude (`toolu_` ids on the wire)
- [x] History round-trip: `assistant.toolCalls` + `tool` messages seeded back
      via `Messages.to_brute` + terminal `seed` — live run 2 confirmed the
      model continues without repeating the call
- [x] `toolCallId` continuity: the model's own id is emitted and correlates
      the echoed `tool` message (verified with real `toolu_…` id)
- [x] Multiple tool calls in one turn: each emits its `TOOL_CALL_*` group
      (unit-covered), then the run ends
- [ ] Live-panel gate: `navigate` fires and the app routes; `queryDataModel`
      round-trips data into the next turn (needs the host-app panel or the
      pydantic-ai verification example)

### Phase 3 — HITL  *(gate: `createDataRecord` form round-trip)*
- [x] `useHumanInTheLoop` verified in the browser (verification harness,
      Swap B): the `go_to_moon` card rendered from streamed `TOOL_CALL_ARGS`,
      waited on human input, and the follow-up run streamed after Launch
- [x] Single-delta `TOOL_CALL_ARGS` granularity confirmed acceptable (the
      card rendered from one whole-JSON delta)
- [x] Cancel/decline path: Abort clicked → agent correctly reported the
      rejection ("Staying on Earth 🌍")
- [ ] host-app-specific gate: `createDataRecord` confirmation form against the
      live host-app panel (cutover checklist, phase 4)

### Verification stage — CopilotKit example with the Ruby agent swapped in
*(start once Phase 1 streams; full pass = Phases 1–3 proven on a stock
CopilotKit app, independent of host-app)*

Harness: `/home/nathan/CopilotKit/examples/integrations/pydantic-ai` — a
Next.js UI (`@copilotkit/react-core/v2`, `runtimeUrl="/api/copilotkit"`,
`useSingleEndpoint={false}`) whose `page.tsx` exercises `useFrontendTool` **and**
`useHumanInTheLoop`, backed by a Python AG-UI agent behind
`HttpAgent({url: AGENT_URL})` in the Next API route. Same topology as host-app,
zero host-app coupling.

- [x] Example vendored at `verification/pydantic-ai` (from `~/src/CopilotKit`),
      Intelligence/license machinery stripped. (Stock Python baseline skipped —
      agent needs an OpenAI key; the Node runtime itself is the oracle.)
- [x] **Swap A**: bare-run route added (POST mount root — the `HttpAgent`
      shape, `examples/bare.rb`); unmodified Node runtime with `AGENT_URL` →
      Ruby proxied text, `setThemeColor` tool call, and `go_to_moon` HITL
      continuation, all decoded by the official `HttpAgent`
- [x] **Swap B**: `scripts/swap-b.sh` parks the Node API route;
      `RUBY_RUNTIME_URL` rewrite proxies the whole surface to Ruby. `/info`
      served by Ruby through the browser URL; run streams end to end
- [x] **Browser gate (chrome-devtools, Swap B mode — no Node runtime)**:
      chat streamed a reply; `setThemeColor` fired for real
      (`--copilot-kit-primary-color: #20B2AA` on the DOM); the `go_to_moon`
      HITL card rendered from streamed `TOOL_CALL_ARGS`, Launch clicked, and
      the follow-up run streamed — screenshots in `verification/screenshots/`
- [x] **A2UI browser gate** (`verification/a2ui-pdf-analyst`, the CopilotKit
      showcase with a custom catalog + SurfaceCanvas): Ruby agent
      (`examples/a2ui_analyst.rb`, catalog id + vocabulary extracted from the
      vendored agent source) replaced the Python agents behind both HttpAgent
      URLs — Claude composed a full revenue dashboard (KPI cards, trend chart,
      region donut, bar chart) rendered on the canvas from our
      ACTIVITY_SNAPSHOT ops. Catalog-membership validation gates renders
      (first attempt used an invented `Column`; caught once the extracted
      component list was wired in). Screenshot: `a2ui-dynamic-dashboard.png`
- [ ] Keep the harnesses (pydantic-ai Swap B + a2ui-pdf-analyst) as
      regression suites; re-run after wire-layer changes

### Phase 4 — A2UI  *(gate: "show me something cool" renders on canvas — cutover-ready)*
- [x] `AgUi::A2ui::Catalog.fetch`: retry loop (20×3s default) + degrade-to-nil,
      `{catalogId, components}` wire shape (injectable http for specs)
- [x] `AgUi::Middleware::A2ui`: `render_a2ui` injected (static schema; catalog
      as a system-message vocabulary), way-out transform → flat
      `ACTIVITY_SNAPSHOT` (`a2ui_operations`: createSurface/updateComponents/
      updateDataModel) + synthetic `TOOL_CALL_RESULT {"status":"rendered"}`
      before `RUN_FINISHED` — LIVE-verified: Claude composed a Card+Text tree
      from the demo catalog (`examples/a2ui.rb`); continuation run confirmed
      the model sees the rendered result
- [x] `a2ui_toolkit` ported (`A2ui::Validate` + `A2ui::Recovery`), upstream
      test suites as the oracle; wired into `Middleware::A2ui#render` with
      `validate_bindings: false` (Node-middleware parity)
- [x] `surfaceId` dedup within a turn: `createSurface` once, updates thereafter
      (runs are stateless — cross-run dedup is the client's SurfaceMessageProcessor)
- [x] Activity messages round-trip: the client sends them back in history;
      `Messages.to_brute` skips them past the model gracefully
- [x] `/info` advertises `a2uiEnabled: true` + `a2ui:{enabled:true}` (live-checked)
- [ ] **Cutover**: flip `runtimeUrl`/Vite proxy to Ruby, Node sidecar on
      standby; run doc-06 definition-of-done against the live host-app panel
      (incl. `log_a2ui_event` / `forwardedProps.a2uiAction` round-trip trace)

### Phase 5 — Context, attachments, reasoning
- [x] `RunAgentInput.context` → system addendum (`Middleware::SystemPrompt`,
      live-verified back in phase 1: model reads `currentPath`)
- [x] Multimodal user content parts → `ruby_llm` Content attachments
      (`data` base64 → io-like with mime-derived filename, `url` as-is;
      all-text arrays still flatten for the pipeline)
- [x] Extended thinking → `REASONING_*` (`TurnEmitter`: lazy open, closes
      before the text phase) — LIVE-verified: `THINKING_BUDGET=2048`
      streamed real deltas then the answer (`examples/claude.rb`)

### Phase 6 — Tail (post-cutover)
- [x] Server tools: `ToolRouter(server_tools: [{name:, description:, parameters:,
      handler:}])` — executes inline, emits `TOOL_CALL_RESULT`
      (Node shape), appends the `:tool` message; `Loop::ToolResult` +
      `MaxIterations` drive the turn — LIVE: weather question executed the
      tool and continued the same run with the answer
- [x] A2UI in-run retry rides the loop: invalid renders emit
      `retrying`/`failed` status activities (Node progression), append the
      structured errors as the tool result, and regenerate up to the
      toolkit's attempt cap
- [x] Suggestions: contract settled from v2 source (doc 05) — server side is
      `forwardedProps.toolChoice` honoring (`ForwardedProps` middleware +
      terminal `with_tools(choice:)`) — LIVE: forced `copilotkitSuggest`
      returned 3 `{title, message}` pills in the client's exact shape
- [x] `/connect` for real: `RunStore::InMemory` (duck-typed, host-pluggable)
      records every wire payload; connect replays historic + live events with
      an ATOMIC snapshot+subscribe (no gap/dup), attaches live via
      Async::Queue fanout — LIVE: mid-run connect received the full stream;
      unknown thread returns the empty-close
- [x] `/stop` for real: the store cancels the run's Async task — LIVE:
      mid-run stop returned `{"stopped":true}` and both streams closed
- [x] Memory foundation: the store IS the per-thread persistence
      (`open_subscription` exposes full replay); redis/SQL adapters are a
      host-side store implementation
- [x] **Cutover shipped** (host-app side): ag-ui 0.1.0 released to rubygems
      and wired in-process behind the existing OIDC-gated controller (verbatim
      sidecar prompt, catalog read from disk, sidecar kept on standby behind
      `COPILOTKIT_PROXY_URL`); prod runs the runtime as a single-count falcon
      service in the same pod (one run store) — the Node sidecar Deployment,
      Service, and image are gone from the manifests. Verified working on the
      live panel by the operator.

### Continuous (every phase)
- [ ] Validate **every emitted event** against the ported schemas in dev/test —
      schema failure = wire-contract bug
- [ ] Keep the Python `server-starter-all-features` running as an oracle; diff
      SSE frames (`curl -N`) Ruby vs Python vs Node for each capability
- [ ] Gate each phase on the **live headless panel**, not just unit tests
