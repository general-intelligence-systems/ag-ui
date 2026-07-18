# 05 — Suggestions, context, attachments

The "extra" client features our panel uses. Each maps to a `RunAgentInput` field
or a run variant — none needs new transport.

## `useAgentContext` → `RunAgentInput.context`

The client shares app state (nav `currentPath` + page map, bpmn snapshot, etc.)
as **context**. It arrives on every `/run` as `context` (and/or
`forwardedProps`). Inject it into the `ruby_llm` conversation as a system/context
addendum before the model runs. Read `docs/concepts/messages.mdx` +
`RunAgentInput` in `sdks/python/ag_ui/core/types.py` for the exact field.

- Nothing to persist; it's re-sent each run.
- Our nav tool depends on this — the agent "sees" the current page from context.

## `useAttachments` → multimodal message parts

Attachments are appended to the user message as **content parts**
(`InputContent`: `text` / `image` / `file`), not a separate field. In
`RunAgentInput.messages`, a user message `content` may be an **array** of parts.
Map those to `ruby_llm`'s multimodal input (it supports images/files/PDF —
`RubyLLM.chat … with:`). Read `docs/concepts/messages.mdx` for the part shapes
and `@ag-ui/core` `InputContentSchema` for exact JSON.

- Our panel already builds these parts on send (`consumeAttachments()` →
  `{ type, source, metadata }`). The gem must accept and forward them.

## `useConfigureSuggestions` / `useSuggestions` → a suggestion run

**SETTLED** — reverse-engineered from the v2 source
(`packages/core/src/core/suggestion-engine.ts` in the CopilotKit repo;
static-path usage cross-checked in the banking showcase, dynamic-path usage
in the host app's per-page hook):

1. **How the reload reaches the server** (fallback/clone transport — the one
   a runtime like ours triggers, since we don't advertise `suggestions: true`):
   the client CLONES the provider agent client-side, seeds a deep copy of the
   consumer's `messages` + `state`, appends a **user message** with a built
   instruction block ("Suggest what the user could say next… by calling the
   `copilotkitSuggest` tool. Provide at least N and at most M… The user has
   the following tools available: <json>. <config.instructions>"), and POSTs
   an ORDINARY `/agent/:id/run` with:
   - `tools: [copilotkitSuggest]` — a normal frontend-tool definition:
     `{ suggestions: [{ title, message }] }` (title = the button text)
   - `forwardedProps.toolChoice = { type: "function",
     function: { name: "copilotkitSuggest" } }` — the FORCED tool choice
2. **What comes back**: the standard client-tool stream — `TOOL_CALL_START`
   (`copilotkitSuggest`) + `TOOL_CALL_ARGS` deltas. The client
   partial-JSON-parses the args as they stream and renders the pills. No
   special events, no structured-output channel.
3. **agentId**: `providerAgentId` defaults to `"default"`; `threadId` is a
   random suggestion id (nothing to persist).
4. **Newer stateless path** (not required): runtimes that advertise
   `suggestions: true` get `POST /agent/:id/suggest` — same run semantics
   without thread persistence. Our runs don't persist anyway; add the alias
   route only if we ever advertise the capability.

**So the server-side work is ONE thing**: honor `forwardedProps.toolChoice`
(force the named tool via ruby_llm's tool-choice preference). Everything else
is the already-working client-tool path.

## Reasoning (extended thinking)

Our panel renders reasoning messages. `ruby_llm` supports "extended thinking"
(control/view/persist). Translate its thinking deltas to `REASONING_MESSAGE_*`
events (`docs/concepts/reasoning.mdx`). Optional for phase 1.

## What we can defer

- **`STATE_SNAPSHOT` / `STATE_DELTA` / `useCoAgent` shared state** — we drive the
  UI via messages + A2UI, not agent-state sync. Skip until something needs it
  (`shared_state.py` / `predictive_state_updates.py` are the templates if so).
- **`/connect` resume** — stub first; the panel's connect effect tolerates a
  no-op. Implement against the run store once threads/memory land.
