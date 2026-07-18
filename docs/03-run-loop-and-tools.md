# 03 — The run loop & tools (the heart of it)

Reference implementations: `integrations/server-starter-all-features/python/
examples/example_server/{agentic_chat,backend_tool_rendering,human_in_the_loop}.py`
and `docs/concepts/tools.mdx` + `docs/concepts/interrupts.mdx`.

## The run loop (over `ruby_llm`)

`POST /agent/:id/run` handler, inside a2a's `env["…stream"].open do |s|`:

```
parse RunAgentInput (messages, tools, context, forwardedProps, threadId, runId)
s.run_started(thread_id:, run_id:)
build a ruby_llm chat:
  - system prompt (our host-app prompt, see 06)
  - history  = RunAgentInput.messages  → ruby_llm messages (incl. tool results)
  - context  = RunAgentInput.context   → injected as context/system addendum
  - tools    = RunAgentInput.tools     → tool SCHEMAS only (do NOT auto-execute)
stream ruby_llm response chunk-by-chunk, translating:
  text delta        → s.text_message_content(message_id:, delta:)
  reasoning delta   → s.reasoning_message_content(delta:)
  tool call         → HANDLE (see below)
s.run_finished(thread_id:, run_id:)
```

`ruby_llm` gives you streaming chunks and the model's tool-call intents. The gem
does the AG-UI translation; `ruby_llm` never sees AG-UI.

## Two kinds of tools — the central distinction

A tool call from the model is one of:

- **Client tool** — its definition arrived in `RunAgentInput.tools` and there is
  **no server handler**. This is 95% of ours (`navigate`, `queryDataModel`,
  `createDataRecord` (HITL), bpmn, chart, page tools). They render UI / use the
  browser session — they *cannot* run on the server.
- **Server tool** — registered on the Ruby agent with a real handler (a
  `ruby_llm` tool / Ruby method). Runs inline.

Decide by name: is it in `RunAgentInput.tools` (client) or in our server
registry (server)?

## Client tools = MULTI-RUN, not suspended fibers

This is the key architectural decision and it makes HITL + frontend tools + A2UI
all trivial. When the model calls a **client** tool:

```
s.tool_call_start(tool_call_id:, tool_call_name:, parent_message_id:)
s.tool_call_args(tool_call_id:, delta: <streamed JSON args>)
s.tool_call_end(tool_call_id:)
s.run_finished(...)          # END THE RUN. Do NOT emit TOOL_CALL_RESULT.
```

Then the **browser**:
1. runs the `useFrontendTool` handler (or renders the `useHumanInTheLoop` form
   and waits for the user),
2. appends a `tool` message `{ role:"tool", toolCallId, content }` to history,
3. POSTs a **new** `/run` with the updated `messages`.

Your next run sees the tool result in `RunAgentInput.messages` and the model
continues. So:

- **No fiber suspension, no websockets, no mid-stream waiting.**
- **HITL is not special** — a `useHumanInTheLoop` tool is just a client tool
  whose browser step happens to show a form. The pause is "run ended; next run
  resumes." (`interrupts.mdx` describes the same shape.)
- The loop is **stateless per run** — everything needed is in `messages`.

Emit multiple client tool calls in one run only if the model produces them in
one turn; otherwise one-per-run is fine and simplest.

## Server tools = inline

When the model calls a **server** tool, run it in the loop and feed the result
back to `ruby_llm` (which continues the same turn). Emit for transparency:

```
s.tool_call_start/args/end(...)
result = handler.call(args)          # ruby_llm tool execute, or your Ruby
s.tool_call_result(message_id:, tool_call_id:, content: result)
# continue the ruby_llm turn with the tool result; keep streaming text
```

`backend_tool_rendering.py` is the reference: the server executes and the client
renders the result via `useRenderToolCall` (our `MessageRow` already does this).

## Gotchas

- **Tool result content is a string.** Match how `@ag-ui/core` encodes
  `ToolMessage.content` (JSON-stringified). Our client already parses it.
- **`toolCallId` continuity.** The `id` you emit in `TOOL_CALL_START` must be the
  same one the client echoes back in its `tool` message — that's how the next
  run correlates. Generate stable ids.
- **Assistant message with tool calls.** When the model calls tools, the
  assistant message in history carries `toolCalls: [...]`; make sure your
  history round-trips that so the model doesn't repeat calls.
- **Don't let `ruby_llm` execute client tools.** Register client tools as
  schema-only (no `execute`), or intercept before execution. This is the one
  place ruby_llm's default (server-side `def execute`) must be bypassed.
