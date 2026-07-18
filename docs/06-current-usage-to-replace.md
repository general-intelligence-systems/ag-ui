# 06 — Current usage to replace (host-app inventory)

Everything the gem must satisfy to be a drop-in for the Node sidecar. Grouped by
server-side (what we replace) and client-side (what the gem must keep working,
unchanged). Paths are in the host-app repo (`ns/ai/host-app`).

## Server-side — what we DELETE and reimplement

`sidecars/copilotkit/server.mjs` (the whole Node process):

| Node piece | Ruby equivalent |
|---|---|
| `CopilotRuntime({ agents: { default } })` | `AgUi.agent`(s) mounted in Rails/Falcon |
| `BuiltInAgent({ model, prompt })` | `ruby_llm` chat with the **same system prompt** (copy it verbatim — see below) |
| model `anthropic/claude-sonnet-4-5` | `ruby_llm` Anthropic model, same id |
| `InMemoryAgentRunner` | stateless run loop (history in `RunAgentInput`); memory later via your redis+SQL |
| `createCopilotHonoHandler({ basePath: "/api/copilotkit" })` | the 3 routes (`/info`, `/agent/:id/run`, `/agent/:id/connect`) |
| `a2ui: { injectA2UITool, schema, defaultCatalogId }` | the A2UI middleware ([04](04-a2ui.md)) |
| catalog fetch from `GET /api/copilotkit/catalog` | same fetch-at-boot with retries |
| `@hono/node-server` | Falcon (already our Rails server) |

**Keep the system prompt identical** — it encodes tool discipline (call
`listDataModels` first, never invent tables, HITL confirmation semantics). It's
in `server.mjs` lines ~70–97; move it into the Ruby agent unchanged.

**Env parity:** `COPILOTKIT_MODEL`, `ANTHROPIC_API_KEY`, `AI_CATALOG_URL`,
listen port. In prod the sidecar shares the pod with Rails; the Ruby version just
becomes Rails routes (no separate process, no Vite proxy hop).

## Client-side — what MUST keep working (unchanged)

The frontend is the conformance target. Every hook below already ships in the
host-app app and talks AG-UI; the gem must serve all of them. (Counts = usages.)

### Core chat (headless panel)
- `useAgent` — `messages`, `isRunning`, `addMessage`, `setMessages`, `abortRun`,
  `detachActiveRun`. → `/run` streaming, message history.
- `useCopilotKit` — `runAgent`, `connectAgent`, `stopAgent`. → `/run` (+ `/connect`
  stub), abort handling.
- `CopilotChatConfigurationProvider agentId="default"` — the `agentId` in routes.
- `useSingleEndpoint={false}` — **multi-route** mode; implement `/agent/:id/*`,
  not the single POST.

### Tools (ALL client-side — the multi-run model, [03](03-run-loop-and-tools.md))
- `useFrontendTool` (×19) — `navigate`, `listDataModels`, `queryDataModel`,
  `renderLineChart`, page tools. → sent in `RunAgentInput.tools`; call → emit
  `TOOL_CALL_*` + end run; browser executes; result in next run.
- `useHumanInTheLoop` (×7) — `createDataRecord`, `updateDataRecord`, `makeItRain`.
  → same client-tool round-trip; the browser step shows a form.
- `useRenderToolCall` / `useDefaultRenderTool` — client renders results/fallbacks;
  server just needs correct `toolCallId` + `TOOL_CALL_RESULT` for server tools.
- `useAgentContext` (×13) — nav + bpmn context. → `RunAgentInput.context`.

### Generative UI / A2UI ([04](04-a2ui.md))
- `createA2UIMessageRenderer`, `A2UIProvider`, `A2UIRenderer`, `useA2UI`,
  `useA2UIActions`, `useA2UIStoreSelector` — the client A2UI stack.
- Requires: `render_a2ui` tool injected server-side, `ACTIVITY_SNAPSHOT` events
  with `activityType:"a2ui-surface"`, catalog served + `defaultCatalogId` pinned,
  `/info` advertising A2UI.

### Message rendering (headless weave — already built)
- `useRenderActivityMessage` (activity/A2UI), `useRenderCustomMessages` (custom
  slots), reasoning. → the gem must emit `ACTIVITY_SNAPSHOT` and
  `REASONING_MESSAGE_*` correctly.

### Suggestions ([05](05-suggestions-context-attachments.md))
- `useConfigureSuggestions` / `useSuggestions` — dynamic suggestions. → suggestion
  run variant (reverse-engineer). Non-blocking; static path already works.

### Attachments ([05](05-suggestions-context-attachments.md))
- `useAttachments` — files as multimodal content parts in the user message.

## Explicitly out of scope (we don't use)
`useCoAgent` / `useCoAgentStateRender` / `STATE_*` shared-state, LangGraph
interrupts (`useLangGraphInterrupt`), MCP-apps middleware. If any is adopted
later, the protocol repo has the template.

## Definition of done (cutover gate)

With the Ruby server behind `runtimeUrl="/api/copilotkit"` and the Node sidecar
off, the live panel must: stream text, run every frontend tool, complete a HITL
record form, render an A2UI surface on the canvas, show reasoning, and carry
`useAgentContext` (agent knows the current page). Suggestions may lag.
