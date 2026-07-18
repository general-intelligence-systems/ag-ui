# 01 — Reference material (source of truth)

Do NOT invent the protocol. Extract it from these. Paths are given both as
`node_modules` (in the host-app repo — already installed at `1.62.x`) and upstream.

## Local skill (read first)

- **`copilotkit-agui` skill** (available in the host-app repo's agent skills).
  Its own description: *"implementing the AG-UI protocol, debugging streaming
  issues… event types, SSE transport, AbstractAgent/HttpAgent patterns, state
  synchronization, tool calls, and human-in-the-loop flows."* This is the
  fastest orientation to the protocol semantics.

## PRIMARY: the protocol repo — `github.com/ag-ui-protocol/ag-ui`

This is the canonical protocol + multiple SDKs. **Prefer it over `node_modules`
dist** — it's the human-readable spec plus reference *server* implementations.
Clone it (`/tmp/ag-ui` while spiking).

- **`docs/concepts/*.mdx`** — the authoritative spec, read in this order:
  `events.mdx` (every event + base props), `messages.mdx`, `tools.mdx`
  (client-executed tools — our whole model), `interrupts.mdx` (HITL),
  `reasoning.mdx`, `capabilities.mdx` (the `/info` payload), `state.mdx`,
  `generative-ui-specs.mdx`, `architecture.mdx`, `serialization.mdx`.
- **`docs/quickstart/server.mdx`** — how to build a *server* that emits events.
  The core pattern (mirror it in Ruby):
  ```python
  async def endpoint(input_data: RunAgentInput, request):
      encoder = EventEncoder(accept=request.headers.get("accept"))
      async def gen():
          yield encoder.encode(RunStartedEvent(...))
          # ... stream text / tool calls ...
          yield encoder.encode(RunFinishedEvent(...))
      return StreamingResponse(gen(), media_type=encoder.get_content_type())
  ```
  `EventEncoder.encode(event)` = the exact SSE framing → this is what a2a's
  `SSE::Stream` does; port `encode` + `get_content_type` faithfully.
- **`sdks/python/ag_ui/`** — the **reference server SDK to port to Ruby**:
  - `core/events.py` — every event as a typed model (field names, shapes).
  - `core/types.py` — `RunAgentInput`, all message roles, `Tool`, `ToolCall`.
  - `core/capabilities.py` — the `/info` capabilities object.
  - `encoder/encoder.py` — SSE (and protobuf) framing + content-type negotiation.
  - `a2ui_toolkit/` — A2UI validation/recovery (server-side A2UI helpers).
- **`integrations/server-starter/python`** and
  **`integrations/server-starter-all-features/python/examples/example_server/`** —
  minimal + full reference servers. The all-features one has a file **per
  capability** we need, each a direct template:
  - `agentic_chat.py` — text streaming (phase 1)
  - `backend_tool_rendering.py` — server-side tools
  - `tool_based_generative_ui.py` / `agentic_generative_ui.py` — generative UI
  - `human_in_the_loop.py` — **HITL** (our record forms / rain)
  - `shared_state.py` / `predictive_state_updates.py` — state sync (defer)
- **`sdks/typescript/`** — the TS SDK (`core`, `client`, `encoder`, `proto`);
  cross-check when the Python and TS disagree.
- **`middlewares/`** — `mcp-*`, `a2a-middleware`, `middleware-starter`. NOTE:
  the A2UI middleware we use is **CopilotKit's** (`@ag-ui/a2ui-middleware`),
  not in this repo — see [04-a2ui](04-a2ui.md).

## The protocol schemas — `@ag-ui/core` (TS form of the same spec)

- `node_modules/@ag-ui/core/dist/index.d.ts`
- Upstream: `github.com/ag-ui-protocol/ag-ui` → `sdks/typescript/packages/core`

The zod schemas — useful for exact JSON when porting to the gem's validation.
Defines everything you must match on the wire:

- **`EventType`** enum — the full event vocabulary (see [02-protocol](02-protocol.md)).
- **Event schemas** (zod) — one per event: `RunStartedEventSchema`,
  `TextMessageContentEventSchema`, `ToolCallStartEventSchema`,
  `ToolCallResultEventSchema`, `ActivitySnapshotEventSchema`,
  `ReasoningMessageContentEventSchema`, `RunFinishedEventSchema`, … Each schema
  is the exact JSON shape. **Port these into the gem's `json_schema` validation.**
- **Message types** — `UserMessage`, `AssistantMessage`, `ToolMessage`,
  `SystemMessage`, `DeveloperMessage`, `ReasoningMessage`, `ActivityMessage`
  (`role: "activity"`, `activityType`, `content`).
- **`RunAgentInput`** — the POST body the client sends to `/run`.
- **`Tool`**, **`ToolCall`**, **`Context`**, **`State`**, **`InputContent`**
  (multimodal message parts — how attachments arrive).

## The server we're replacing — `@copilotkit/runtime/v2`

- `sidecars/copilotkit/node_modules/@copilotkit/runtime/dist/*`
- Upstream: `github.com/CopilotKit/CopilotKit` → `packages/runtime/src/v2`

This is the **authoritative wire behaviour** — read it to confirm anything the
schemas don't spell out:

- `createCopilotHonoHandler` / `createCopilotRuntimeHandler` — the route table
  (`GET /info`, `POST /agent/:agentId/run`, `GET|POST /agent/:agentId/connect`)
  and the SSE response (`text/event-stream`).
- The **`/info`** payload (capabilities + agents advertised to the client).
- `BuiltInAgent` — the run loop we're mirroring (message → LLM → stream → tool
  calls → continue). Our Ruby loop should behave the same, over `ruby_llm`.
- `InMemoryAgentRunner` — the (stateless) run/thread bookkeeping.
- The **SSE encoder** — exactly how each event is framed on the wire (see below).

## The client (read to learn what it SENDS/EXPECTS) — `@copilotkit/react-core/v2`

- `node_modules/@copilotkit/react-core/dist/*`
- Upstream: `github.com/CopilotKit/CopilotKit` → `packages/react-core/src/v2`

Not reimplemented — but it defines the contract from the other side:

- `useAgent`, `useCopilotKit` (`runAgent`, `connectAgent`, `stopAgent`) — when
  and how the client POSTs `/run` and `/connect`, and how it appends tool
  results before re-running.
- `useRenderActivityMessage`, `createA2UIMessageRenderer` — how activity/A2UI
  events are consumed (so we emit them correctly).
- `useConfigureSuggestions` / `useSuggestions` — how the client requests
  suggestion generation (a run variant — see [05](05-suggestions-context-attachments.md)).

## Transport / encoding — `@ag-ui/client` + `@ag-ui/encoder`

- `node_modules/@ag-ui/client`, `node_modules/@ag-ui/encoder`
- The `HttpAgent` decodes the SSE stream; the encoder defines the framing
  (SSE `data: <json>\n\n`, and a protobuf variant). **Mirror the SSE framing
  the encoder produces** — confirm content-type, per-event delimiter, and
  whether an `event:` line is used.

## A2UI — `@ag-ui/a2ui-middleware` + `@copilotkit/a2ui-renderer`

- `node_modules/@ag-ui/a2ui-middleware` — injects the `render_a2ui` tool and
  converts the tool-call stream into `a2ui-surface` **activity** snapshots.
  This is the exact transform we port in [04-a2ui](04-a2ui.md).
- `@copilotkit/a2ui-renderer` — the client side (catalog, `A2UIRenderer`); read
  only to confirm the `a2ui_operations` shape we must emit.

## The Ruby substrate to reuse — `~/brute/a2a`

- `lib/a2a/server.rb`, `lib/a2a/server/middleware/sse_stream.rb`,
  `lib/a2a/server/sse/*`, `lib/a2a/protocol/json_schema*`, `lib/a2a/agent.rb`,
  `docs/_core_features/streaming.md`, `docs/_core_features/rails-and-rack-hosts.md`.
- See [07-gem-design](07-gem-design-and-plan.md) for the reuse map.

## The LLM engine — `ruby_llm`

- `github.com/crmne/ruby_llm` → `lib/ruby_llm/{chat,tool,agent,streaming,chunk}.rb`.
- We use: chat, streaming chunks, tool *schemas* (not auto-execute), extended
  thinking, structured output, `acts_as_chat` (optional, for persistence).
