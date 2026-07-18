# 07 — Gem design & build plan

## Reuse map — `~/brute/a2a` → `ag-ui`

The a2a gem is the substrate. Reuse verbatim where marked ✅.

| a2a | ag-ui | reuse |
|---|---|---|
| `A2A.agent { }` → Rack app, mount in Rails routes | `AgUi.agent { }` | ✅ pattern (`docs/_core_features/rails-and-rack-hosts.md`) |
| `Server` Rack::Builder pipeline + `triage` | route `/info`, `/agent/:id/run`, `/agent/:id/connect` | ✅ pattern |
| `Server::Middleware::SSEStream` + `SSE::Stream` (Async fibers, auto-finish) | the run stream | ✅ **verbatim** — the hard part |
| typed emitters (`s.message`, `s.artifact_update`) | AG-UI emitters (`s.run_started`, `s.text_message_content`, `s.tool_call_*`, `s.activity_snapshot`, `s.reasoning_*`, `s.run_finished`) | new vocab, same mechanism |
| `protocol/json_schema` validation | AG-UI event schemas (port from `sdks/python/ag_ui/core/events.py` / `@ag-ui/core` zod) | ✅ mechanism |
| `well_known` agent card | `/info` capabilities (from `sdks/python/ag_ui/core/capabilities.py`) | ✅ pattern |
| task store | run/thread store (later, your redis+SQL) | ✅ mechanism |
| `client.rb`, JSON-RPC/REST/gRPC bindings, protobuf | — (JS frontend is the client; SSE only) | drop |

The **EventEncoder** (`sdks/python/ag_ui/encoder/encoder.py`) is the one new
transport piece — port its SSE framing + content-type into the stream layer.

## Module layout

```
lib/ag_ui.rb
lib/ag_ui/agent.rb            # AgUi.agent {} → Rack app (mirror a2a/agent.rb)
lib/ag_ui/server.rb           # Rack::Builder pipeline + routes
lib/ag_ui/server/
  triage.rb                   # dispatch /info, /run, /connect
  middleware/sse_stream.rb    # reuse a2a
  sse/{stream,event_encoder}.rb  # port EventEncoder (SSE framing)
  info.rb                     # GET /info capabilities
lib/ag_ui/events.rb           # typed emitters + schemas (the AG-UI vocabulary)
lib/ag_ui/run_input.rb        # parse/validate RunAgentInput
lib/ag_ui/middleware/tool_router.rb # client-defer vs server-exec routing (03)
lib/ag_ui/middleware/a2ui.rb  # render_a2ui injection + activity conversion (04)
lib/ag_ui/protocol/json_schema.rb  # reuse a2a validation
```

## The agent DSL (target shape)

```ruby
# config/routes.rb (or a Rack mount)
HOST_AGENT = AgUi.agent(agent_id: "default") do |run|
  run.model    "anthropic/claude-sonnet-4-5"   # ruby_llm
  run.prompt   HOST_SYSTEM_PROMPT           # copied verbatim from server.mjs
  run.a2ui     catalog_url: ENV["AI_CATALOG_URL"]   # inject render_a2ui + activities
  # server-side tools (optional) registered here; client tools come from RunAgentInput
end
# mount at /api/copilotkit  → gives /info, /agent/default/run, /agent/default/connect
```

The stream body is the a2a pattern:

```ruby
env["ag_ui.stream"].open(thread_id:, run_id:) do |s|
  s.run_started
  ruby_llm_chat.stream do |chunk|
    case chunk
    in { text: }              then s.text_message_content(message_id:, delta: text)
    in { reasoning: }         then s.reasoning_message_content(delta: reasoning)
    in { tool_call: tc }      then handle_tool(s, tc)   # client → end run; server → inline
    end
  end
  s.run_finished
end
```

## Phased build (each phase = a conformance gate against the live panel)

1. **Transport + text.** `/info` (static caps) + `/agent/default/run` streaming
   `RUN_STARTED → TEXT_MESSAGE_* → RUN_FINISHED` over `ruby_llm`. Point
   `runtimeUrl` here; send one message; watch it stream. Reference:
   `agentic_chat.py`. *Proves SSE framing + `useAgent`.*
2. **Client tools (multi-run).** Accept `RunAgentInput.tools`; emit `TOOL_CALL_*`
   + end run; resume on next run with the `tool` message. Test `navigate` +
   `queryDataModel`. Reference: `tool_based_generative_ui.py`, `tools.mdx`.
3. **HITL.** Same path; test `createDataRecord` form round-trip. Reference:
   `human_in_the_loop.py`, `interrupts.mdx`.
4. **A2UI.** Catalog fetch + `render_a2ui` injection + `ACTIVITY_SNAPSHOT`. Test
   "show me something cool" → canvas. Reference: [04](04-a2ui.md).
5. **Context + attachments + reasoning.** `RunAgentInput.context` → prompt;
   multimodal parts → `ruby_llm`; thinking → `REASONING_*`.
6. **Server tools** (if any) + **suggestions** (reverse-engineered) +
   **`/connect`** + **memory** (redis+SQL against `threadId`).

Run the **Node sidecar in parallel** (different port) until phase 4 passes; flip
`runtimeUrl` / the Vite proxy to the Ruby server, keep the sidecar as fallback,
then delete it.

## Conformance harness

- Port `@ag-ui/core` event schemas into `protocol/json_schema` and **validate
  every emitted event** in dev — a schema failure is a wire-contract bug.
- Keep the `sdks/python` server-starter running as an oracle: same panel, diff
  the SSE frames (`curl -N` the `/run` endpoint) between Node/Python/Ruby.
- a2a's `test_helpers.rb` pattern → an `ag_ui/test_helpers.rb` that drives `/run`
  over a real Falcon server and asserts the event sequence.

## Effort

Smaller than the a2a gem you already shipped: the transport is reused, the new
surface is ~6 focused files (events, run_input, middleware, tool_router, a2ui, info).
Phase 1 is a spike (a day-ish); tools/A2UI are the substance; suggestions +
`/connect` + memory are the tail.
