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

This is the one that needs a design decision — **investigate the exact client
call before implementing.** The client publishes a suggestion *config*
(`instructions`, `minSuggestions`, `maxSuggestions`, `available`) and, when it
reloads, asks the agent to **generate** suggestions.

Open questions to answer from the client source
(`@copilotkit/react-core/v2` `use-configure-suggestions` /
`use-suggestions`, and `docs/concepts` if covered):

1. **How does the reload reach the server?** Almost certainly a normal `/run`
   with the `instructions` provided as a special system/developer message (or via
   `forwardedProps`), expecting a **structured** list back.
2. **What shape must come back?** Suggestions are `{ title, message }[]`. The
   client likely expects them via a specific tool call or structured output, not
   free text. Nail this from the client's parser.
3. **Which `agentId`?** `providerAgentId` defaults to `"default"` — our sidecar
   agent generates them. So the same `ruby_llm` model produces them; use
   `with_schema` (structured output) to return `[{title, message}]` reliably.

Until this is reverse-engineered, suggestions can stay on the host-app
registry-static path (already shipped) — dynamic suggestions are a nice-to-have,
not a blocker for cutover.

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
