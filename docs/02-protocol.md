# 02 — Protocol: endpoints, SSE, RunAgentInput, events

Confirmed against `@copilotkit/runtime@1.62` and `@ag-ui/core`. Anything marked
**(confirm)** must be verified against the encoder/runtime source before relying
on it — the schemas are the spec.

## Endpoints (multi-route / REST mode)

Base path `/api/copilotkit` (our provider sets `useSingleEndpoint={false}`, so we
implement the multi-route surface, NOT the single POST endpoint):

| Method | Path | Purpose |
|---|---|---|
| `GET`  | `/info` | Capabilities + agent list. The provider fetches this on mount to feature-detect (a2ui, etc.) and to learn `agents: { default }`. |
| `POST` | `/agent/:agentId/run` | **The run.** Body = `RunAgentInput`. Response = `text/event-stream` of AG-UI events. |
| `GET`/`POST` | `/agent/:agentId/connect` | Resume/reattach to an in-flight run. **Stub initially** (our panel tolerates a no-op); implement later against the run store. |

`:agentId` is `default` for us.

## SSE framing (CONFIRMED against `sdks/python/ag_ui/encoder/encoder.py`)

- Response `Content-Type: text/event-stream`.
- One AG-UI event per SSE frame, JSON-encoded: `data: {"type":"…", …}\n\n`.
- **No `event:` line, no `id:`, no heartbeat** in the reference encoder.
  Keys are **camelCase**; null/absent fields are **omitted** (`exclude_none`).
- Maps cleanly onto a2a's `SSE::Stream` — you emit one validated event object per
  `s.<event>` call.

## `RunAgentInput` (the POST body)

Fields we must read (from `RunAgentInputSchema`):

- `threadId` — conversation id (persist against this for memory).
- `runId` — this run's id (echo in `RUN_STARTED` / `RUN_FINISHED`).
- `messages` — the full history: `user` / `assistant` (with `toolCalls`) /
  `tool` (results) / `system` / `developer` / `activity` / `reasoning`. **This is
  where client-executed tool results come back** (see [03](03-run-loop-and-tools.md)).
- `tools` — the **frontend** tool definitions (`useFrontendTool` /
  `useHumanInTheLoop`): `{ name, description, parameters (JSON schema) }`. These
  have **no server handler** — a call to one is deferred to the browser.
- `context` — `useAgentContext` values (nav state, current page, etc.).
- `forwardedProps` — misc client props (e.g. the A2UI `a2uiAction` bridge).
- `state` — agent-state sync (we largely don't use it; safe to ignore first).

## Event vocabulary (`EventType`)

Every event object is `{ "type": "<EVENT_TYPE>", …fields }`. Group by concern:

### Run lifecycle
- `RUN_STARTED` `{ threadId, runId }` — emit first.
- `RUN_FINISHED` `{ threadId, runId, result? }` — emit last (also ends a run that
  handed off a client tool).
- `RUN_ERROR` `{ message, code? }`.
- `STEP_STARTED` / `STEP_FINISHED` `{ stepName }` — optional structure.

### Assistant text
- `TEXT_MESSAGE_START` `{ messageId, role: "assistant" }`
- `TEXT_MESSAGE_CONTENT` `{ messageId, delta }` — stream deltas.
- `TEXT_MESSAGE_END` `{ messageId }`
- `TEXT_MESSAGE_CHUNK` — alternative single-shot; prefer START/CONTENT/END.

### Tool calls (the model wants a tool)
- `TOOL_CALL_START` `{ toolCallId, toolCallName, parentMessageId? }`
- `TOOL_CALL_ARGS` `{ toolCallId, delta }` — stream the JSON args.
- `TOOL_CALL_END` `{ toolCallId }`
- `TOOL_CALL_RESULT` `{ messageId, toolCallId, content }` — **only for
  SERVER-side tools** (we produced the result). Client tools do NOT get a result
  event from us — the browser produces it and sends it back in the next `/run`.

### Reasoning (extended thinking)
- `REASONING_START` / `REASONING_END`
- `REASONING_MESSAGE_START` / `REASONING_MESSAGE_CONTENT` `{ delta }` / `REASONING_MESSAGE_END`
- (`THINKING_*` are deprecated aliases — do not emit.)

### Activity (A2UI + generic) — see [04](04-a2ui.md)
- `ACTIVITY_SNAPSHOT` `{ messageId, activityType, content, replace=true }` (flat — confirmed)
- `ACTIVITY_DELTA` `{ messageId, activityType, patch }` (JSON Patch)

### State / messages (defer)
- `STATE_SNAPSHOT` / `STATE_DELTA` — only if we adopt agent-state sync.
- `MESSAGES_SNAPSHOT` — full message list push.
- `RAW` / `CUSTOM` — escape hatches.

## Minimum viable event set (phase 1)

`RUN_STARTED` → `TEXT_MESSAGE_START` → `TEXT_MESSAGE_CONTENT`* → `TEXT_MESSAGE_END`
→ `RUN_FINISHED`. That alone makes `useAgent().messages` stream in the panel and
proves transport before any tool/A2UI work.
