# Verification harness

A stock CopilotKit example (`pydantic-ai/`, vendored from
`~/src/CopilotKit/examples/integrations/pydantic-ai`, Intelligence/license
machinery stripped) used to conformance-test the `ag_ui` gem against the real
CopilotKit frontend — independent of host-app. Re-run this after any change to
the wire layer (events, encoder, routes, run loop, tool routing).

The example UI exercises exactly the features the gem must serve:
`useFrontendTool` (`setThemeColor`), `useHumanInTheLoop` (`go_to_moon`),
streamed chat, `useSingleEndpoint={false}` multi-route mode — the same
provider config host-app uses.

## Two modes

| | Path | What it proves |
|---|---|---|
| **Swap A** | browser → Next API route → **Node CopilotKit runtime** → `HttpAgent` → Ruby bare endpoint | our SSE stream + event vocabulary decode cleanly in the official client |
| **Swap B** | browser → Next rewrite proxy → **Ruby full runtime surface** (no Node) | our `/info`, routes, and streams drive the frontend directly |

## Setup (once)

```bash
cd verification/pydantic-ai
npm install
```

The chrome-devtools MCP server drives the browser (`.mcp.json` at the repo
root; on NixOS it needs the `--executablePath` pointing at
`/run/current-system/sw/bin/google-chrome-stable`).

## Swap A

```bash
# 1. Ruby bare agent (the HttpAgent endpoint shape: POST / => run)
ANTHROPIC_API_KEY=sk-... PORT=9395 bundle exec ruby examples/bare.rb

# 2. UI with the Node runtime pointed at Ruby
cd verification/pydantic-ai
AGENT_URL=http://127.0.0.1:9395/ npm run dev:ui
```

Wire check (through the Node runtime — expect our frames, with RUN_STARTED
enriched by the runtime's `input` echo):

```bash
curl -sN -X POST http://localhost:3000/api/copilotkit/agent/default/run \
  -H 'content-type: application/json' \
  -d '{"threadId":"t1","runId":"r1","state":null,"messages":[{"id":"u1","role":"user","content":"Say hello in exactly five words."}],"tools":[],"context":[],"forwardedProps":null}'
```

## Swap B

```bash
# 1. Park the Node runtime route (app routes beat rewrites)
verification/pydantic-ai/scripts/swap-b.sh        # --undo restores Swap A

# 2. Ruby full-surface server
ANTHROPIC_API_KEY=sk-... bundle exec ruby examples/claude.rb   # :9292

# 3. UI proxying the whole surface to Ruby
cd verification/pydantic-ai
RUBY_RUNTIME_URL=http://127.0.0.1:9292 npm run dev:ui
```

Sanity: `curl -s http://localhost:3000/api/copilotkit/info` must return the
RUBY envelope (`"className":"BuiltInAgent"`, `"telemetryDisabled":true`) —
if you see `"description":""` and thread endpoints enabled, the Node runtime
is still in the path (swap-b.sh not run, or dev server not restarted).

## Browser gates (drive with the chrome-devtools skill)

Open `http://localhost:3000` (first compile is slow — `wait_for` the
"chatting with an agent" welcome text) and run, in order:

1. **Text**: send `Introduce yourself in one short sentence.` → a streamed
   assistant reply renders in the sidebar.
2. **Frontend tool**: send `Please set the theme color to a nice teal.` →
   the reply confirms, and the page's `<main>` carries
   `--copilot-kit-primary-color` set to the chosen colour
   (`evaluate_script` it). This proves the full multi-run cycle:
   TOOL_CALL_* → run ends → browser executes → new run with the tool result.
3. **HITL confirm**: send `Take me to the moon!` → the "Ready for Launch?"
   card renders (from streamed TOOL_CALL_ARGS) and waits; click
   **🚀 Launch!** → card flips to "Mission Launched" and a follow-up
   assistant message streams.
4. **HITL decline**: send it again; click **✋ Abort** → "Mission Aborted"
   and the agent's reply acknowledges the rejection (no retry loop).

Screenshots of a passing run: `verification/screenshots/` (2026-07-18,
Swap B, commit `895f7f3`).

## A2UI harness: `a2ui-pdf-analyst/`

The CopilotKit showcase with a custom catalog (frontend-owned renderers,
`SurfaceCanvas`) and `HttpAgent`s to a backend on :8123 — the full A2UI
architecture. The Ruby agent replaces both Python agents:

```bash
# 1. Ruby A2UI agent on the showcase's agent port (serves /fixed + /dynamic;
#    catalog id + component vocabulary are extracted from the vendored
#    agent/src/catalog.py — nothing hand-transcribed)
ANTHROPIC_API_KEY=sk-... PORT=8123 bundle exec ruby examples/a2ui_analyst.rb

# 2. UI (npm install --ignore-scripts once — the postinstall hooks build the
#    Python agent we replace)
cd verification/a2ui-pdf-analyst && npx next dev
```

Gate: open `http://localhost:3000/dynamic`, ask for a dashboard
("Show me a revenue dashboard for a fictional coffee company: KPIs, a
revenue trend, and a breakdown by region"). The chat streams a preamble +
a SURFACE chip, and the canvas renders the composed dashboard from our
`ACTIVITY_SNAPSHOT` operations. A passing run:
`screenshots/a2ui-dynamic-dashboard.png`.

Notes:
- The chat input needs real key events — use `type_text`, not `fill`
  (React state doesn't observe `fill`).
- Catalog-membership validation matters: without the extracted component
  list the model can invent components (`Column`) that reach the canvas as
  "Unknown component"; with it, invalid surfaces fail server-side with
  structured errors.

## Limits

- The stock Python agents need OpenAI keys; we never run them — the
  unmodified Node runtime in Swap A is the conformance oracle.
- Node runtime `/info` differs from ours by design in Swap A (it advertises
  its own runner's thread endpoints); parity of OUR `/info` is asserted in
  Swap B and in the gem's specs.
