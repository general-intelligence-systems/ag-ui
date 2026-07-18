# 09 — host-app ground truth (Phase 0 findings)

Extracted 2026-07-18 from the host-app repo
(`<host-app repo>`): `@copilotkit/runtime@1.62.2`
dist, `@ag-ui/a2ui-middleware` dist, `sidecars/copilotkit/server.mjs`, the
`copilotkit-agui` skill (`.agents/skills/copilotkit-agui/`), and
`@copilotkit/react-core`. Load-bearing claims were verified against the actual
dist source, with file:line refs.

## 1. `GET /info` — the exact envelope

Verbatim from `runtime/dist/v2/runtime/handlers/get-runtime-info.mjs` (~l.35):

```javascript
{
  version: VERSION,                          // "1.62.2"
  agents: { "<id>": { name, description?, className, capabilities? } },
  audioFileTranscriptionEnabled: !!runtime.transcriptionService,
  mode: runtime.mode,                        // "sse" for us
  threadEndpoints: { list, inspect, mutations, realtimeMetadata },  // booleans
  a2uiEnabled: isA2UIEnabled(runtime.a2ui),  // ← THE a2ui feature-detect flag (top level!)
  ...enabled ? { a2ui: { enabled: true, agents?: [...] } } : {},
  openGenerativeUIEnabled: !!runtime.openGenerativeUI,
  telemetryDisabled: isTelemetryDisabled()
}
```

Our static Ruby response (phases 1–3, flip `a2uiEnabled` true in phase 4):

```json
{ "version": "1.62.2",
  "agents": { "default": { "name": "default", "className": "BuiltInAgent" } },
  "audioFileTranscriptionEnabled": false,
  "mode": "sse",
  "threadEndpoints": { "list": false, "inspect": false, "mutations": false, "realtimeMetadata": false },
  "a2uiEnabled": false,
  "openGenerativeUIEnabled": false,
  "telemetryDisabled": true }
```

- A2UI detection = **top-level `a2uiEnabled: true`** (+ optional `a2ui: {enabled: true}`).
- `Content-Type: application/json`, status 200.

## 2. Route table (fetch-router.mjs — suffix match after basePath strip)

| Route | Method | Ruby plan |
|---|---|---|
| `/info` | GET | implement |
| `/agent/:agentId/run` | POST | implement |
| `/agent/:agentId/connect` | **POST** (not GET) | stub: 200 SSE, close immediately |
| `/agent/:agentId/stop/:threadId` | POST | **implement-lite** — `stopAgent` calls this; ack + cancel the Async task if running |
| `/threads*` (7 routes), `/transcribe`, `/annotate`, `/cpk-debug-events` | various | skip — advertised off via `threadEndpoints`/`audioFileTranscriptionEnabled` |

- Unknown path / failed URI decode → 404.
- Bad `/run` body → **400** `{"error": "Invalid request body", "details": "…"}`.
- `/connect` body = `RunAgentInput` + optional `lastSeenEventId`. Unknown
  thread ⇒ 200 + immediately-completed SSE stream (EOF, zero events) — the
  panel tolerates exactly this (in-memory.mjs l.153-178), so the stub is
  literally "open stream, close stream".

## 3. SSE framing, headers, CORS

- `@ag-ui/encoder` dist l.204: **`data: <JSON>\n\n` only** — no `event:`/`id:`
  lines, no heartbeats, no `:ping` comments. Matches the Python reference.
- Response headers (sse-response.mjs l.98-105):
  `Content-Type: text/event-stream`, `Cache-Control: no-cache`,
  `Connection: keep-alive`. Status 200 immediately.
- CORS (fetch-cors.mjs): OPTIONS → 204 + allow-all by default. Moot for us
  (same-origin once in Rails) but keep OPTIONS tolerant.
- Forwarded headers (header-utils.mjs): any `x-*` + `Authorization` are passed
  to the agent — preserve access to these in the run loop for later auth.

## 4. BuiltInAgent run semantics (runtime/dist/agent/index.mjs)

- **Text**: emits `TEXT_MESSAGE_CHUNK` (aisdk converter), NOT the
  START/CONTENT/END triad. The client's `transformChunks` expands chunks into
  triads, so **both forms are legal**. Ruby emits the triad (spec-preferred).
  ⚠ Oracle caveat: SSE diffs vs Node will benignly differ here.
- **Client tools**: `input.tools` → schema-only Vercel tools (l.445).
  `interrupt` flags exist **only** on server-registered `config.tools` (l.582)
  — a frontend tool can never take the interrupt path. When the turn ends on
  client tool calls: `TOOL_CALL_START/ARGS/END` then **plain**
  `RUN_FINISHED {threadId, runId}` — no `result`, no `outcome` (l.785-798,
  l.918-928). **Multi-run model confirmed end-to-end.**
- **Server tools**: `TOOL_CALL_RESULT { role:"tool", messageId: randomUUID(),
  toolCallId, content: <serialized string> }` (l.775-782), then the turn
  continues.
- **Abort** (`stopAgent`): plain `RUN_FINISHED` (l.606).
- **Errors**: `RUN_ERROR { message, threadId, runId }` — note it adds
  threadId/runId beyond the core schema (schemas are `extra="allow"`; do the
  same).
- **Message ids**: taken from provider stream part ids; ids matching
  `/^(txt|reasoning|msg)-0$/` are replaced with `randomUUID()`.
- Capabilities advertised by BuiltInAgent include
  `humanInTheLoop: { interrupts: true }` (l.367) — harmless to omit for us
  since host-app doesn't use interrupt-flagged server tools.

## 5. `server.mjs` — config to reproduce

- **Catalog fetch**: `AI_CATALOG_URL` (default
  `http://localhost:9292/api/copilotkit/catalog`), **20 retries × 3000 ms**;
  expects `{ catalogId, components }` else "malformed catalog"; on total
  failure **degrade**: still `injectA2UITool: true` with no schema (A2UI
  degraded, not fatal). Success log format:
  `loaded A2UI catalog <id> (<n> components) from <url>`.
- **A2UI config**: `{ injectA2UITool: true, schema: catalog.components,
  defaultCatalogId: catalog.catalogId }`.
- **Env**: `COPILOTKIT_MODEL` (default `anthropic/claude-sonnet-4-5`),
  `COPILOTKIT_PORT` (5100), `ANTHROPIC_API_KEY`.
- **System prompt**: lines 70–97 — copy verbatim into the Ruby agent (full text
  captured; it encodes navigate/queryDataModel/listDataModels discipline and
  the HITL `{status: created|updated|cancelled|error}` semantics).

## 6. A2UI middleware (`@ag-ui/a2ui-middleware` dist) — the transform to port

- **Injected tool**: name `render_a2ui`, description "Render a dynamic A2UI
  v0.9 surface with structured parameters. Follow the A2UI render tool usage
  guide provided in context." Parameters schema is **STATIC**:
  `{ surfaceId: string, components: array (root id must be "root"), data?: object }`,
  required `[surfaceId, components]`.
- **The catalog does NOT shape the tool schema** — it's injected into
  `RunAgentInput.context` as an entry described "A2UI Component Schema —
  available components for generating UI surfaces…". Port both halves.
- **Transform** (per `render_a2ui` call, all with `replace: true`):
  1. `TOOL_CALL_START` ⇒ `ACTIVITY_SNAPSHOT { messageId:
     "a2ui-surface-<toolCallId>", activityType: "a2ui-surface",
     content: { status: "building" } }`.
  2. During `TOOL_CALL_ARGS`: progressive building snapshots, throttled
     (~every 20 tokens).
  3. On complete valid args ⇒ snapshot with `content.a2ui_operations`:
     `[{version:"v0.9", createSurface:{surfaceId, catalogId}},
       {version:"v0.9", updateComponents:{surfaceId, components}},
       {version:"v0.9", updateDataModel:{surfaceId, path:"/", value:…}}]`.
  4. Validation failure ⇒ `content: { status:"retrying", attempt, maxAttempts,
     errors }`; exhausted ⇒ `{ status:"failed", … }`.
  5. `TOOL_CALL_*` events **pass through** (not swallowed); `RUN_FINISHED` is
     **held back** and preceded by a synthetic
     `TOOL_CALL_RESULT { toolCallId, content: '{"status":"rendered"}' }` for
     each pending `render_a2ui` call — so the model sees a result next run.
- **Dedup**: set of emitted surfaceIds; `createSurface` once per surface.
  Multi-surface calls use `messageId: "a2ui-surface-<surfaceId>-<toolCallId>"`.
- **catalogId fallback chain**: args → `defaultCatalogId` →
  `https://a2ui.org/specification/v0_9/basic_catalog.json`.
- Also injects a **`log_a2ui_event`** tool (user-action bridge from the
  surface back to the agent, paired with the `forwardedProps.a2uiAction`
  bridge). → follow-up: trace its round-trip when building phase 4.
- Operations vocabulary consumed by the renderer: `createSurface`,
  `updateComponents`, `updateDataModel`, `deleteSurface` (all
  `{version:"v0.9", <op>:{surfaceId, …}}`).
- **History**: activity messages persist as first-class
  `{role:"activity", activityType, content}` messages, stored by the client
  and sent back in `RunAgentInput.messages` — **no server-side reverse
  transform needed** (the client sends them; we just round-trip them past the
  model gracefully).

## 7. `copilotkit-agui` skill — protocol rules worth keeping

- Every run MUST start `RUN_STARTED` and end `RUN_FINISHED`/`RUN_ERROR`.
- `TEXT_MESSAGE_CONTENT.delta` must be **non-empty** (skip empty chunks).
- `TEXT_MESSAGE_CHUNK`/`TOOL_CALL_CHUNK` auto-expand client-side
  (`transformChunks`) — triads and chunks are interchangeable on the wire.
- Sequential runs only: each run completes before the next starts.
- Reference files live in the skill's `references/` (protocol-spec,
  building-agents, event-flow-diagrams, client-sdk) — use while implementing.

## 8. Decision: depend on the `brute` gem (settled)

Depend on `brute` rather than vendoring. Nothing found in Phase 0 argues
against it: the run loop needs exactly `Loop::ToolResult` + short-circuit +
`env[:events]`, brute's deps (rack ~3.0, async ~2.0, json_schemer) are already
ours via a2a, and same-author maintenance makes vendoring pure duplication.
The one adaptation: our `ToolRouter` middleware replaces brute's stock
`ToolPipeline` (client/server routing is AG-UI-specific), while
`Loop::ToolResult`, `MaxIterations`, and the OTel middleware are used as-is.

## Corrections to earlier docs discovered in Phase 0

- `/connect` is **POST only** (doc 02 said GET|POST — corrected).
- The client's `stopAgent` uses **`POST /agent/:agentId/stop/:threadId`** — a
  route the plan didn't list; added to the checklist (phase 1 route table).
- Node emits `TEXT_MESSAGE_CHUNK`, not the triad — triad remains correct for
  Ruby, but SSE-oracle diffs vs Node will differ there by design.
