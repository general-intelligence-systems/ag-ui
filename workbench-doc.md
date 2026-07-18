# ag-ui (Ruby) — Build Coordination

Building a Ruby gem that implements the AG-UI protocol server side (SSE event
streaming, run loop, client-tool round-trips, A2UI generative UI) on top of our
existing transport + middleware substrates. Local plan docs: `docs/01`–`09` in
the project repo (phases, checklist, ground truth).

```status
state: building
- 2026-07-18T05:06Z Phase 0 complete: protocol ground truth extracted and verified (SSE framing, /info envelope, route table, run-loop semantics, A2UI transform); recorded in local doc 09
- 2026-07-18T05:06Z Decision settled: reuse our middleware-pipeline gem for the run loop rather than vendoring the pattern
## Checklist
- [x] Phase 0 — ground truth + decisions
- [ ] Phase 0 — gem scaffold
- [ ] Phase 1 — transport + streaming text
- [ ] Phase 2 — client tools (multi-run)
- [ ] Phase 3 — human-in-the-loop
- [ ] Verification — reference example with Ruby agent swapped in
- [ ] Phase 4 — A2UI (cutover gate)
- [ ] Phase 5 — context / attachments / reasoning
- [ ] Phase 6 — tail (server tools, suggestions, connect, memory)
```

## Task board

```board
## Todo
- [ ] Scaffold gem: gemspec, entry point, rspec, module layout #phase0
- [ ] Port SSE stream layer + AG-UI event encoder framing #phase1
- [ ] Typed event emitters + JSON-schema validation (run/text vocabulary) #phase1
- [ ] Parse/validate RunAgentInput (tolerant, multimodal content) #phase1
- [ ] Routes: info, run, connect stub, stop #phase1
- [ ] Middleware pipeline skeleton + LLM terminal proc #phase1
- [ ] Conformance gate: SSE diff vs reference server; live panel streams #phase1
- [ ] Tool-call emitters + router middleware (client tool ends run cleanly) #phase2
- [ ] History round-trip: assistant toolCalls + tool results; id continuity #phase2
- [ ] Gate: navigation + data-query tools work end to end #phase2
- [ ] HITL gate: record-form round-trip incl. cancelled path #phase3
- [ ] Verification swap A: reference example, Ruby endpoint replaces Python agent (baseline SSE diff) #verify
- [ ] Verification swap B: Ruby serves the full runtime surface, no Node in path; keep as regression harness #verify
- [ ] A2UI: catalog fetch with retry/degrade, tool injection (static schema + catalog-in-context) #phase4
- [ ] A2UI transform: progress snapshots, operations payload, surface dedup, synthetic tool result #phase4
- [ ] Trace surface user-action event round-trip #phase4
- [ ] Advertise A2UI in info; cutover to Ruby server with old sidecar on standby #phase4
- [ ] Context injection, attachments to multimodal input, thinking to reasoning events #phase5
- [ ] Tail: server tools, suggestions, real connect, thread memory, delete sidecar #phase6
## In Progress
## Done
- [x] Study transport substrate + write plan docs 01–07
- [x] Clone protocol repo; confirm SSE framing, event shapes, input schema, capabilities
- [x] Fix activity-snapshot shape error found in our plan docs
- [x] Research middleware-pipeline gem; decide to depend on it
- [x] Extract runtime ground truth: info envelope, route table, connect/stop semantics, run-finish behaviour
- [x] Extract A2UI middleware transform + dedup rules
- [x] Read the AG-UI protocol skill; capture protocol rules
- [x] Pick verification harness: reference example exercising frontend tools + HITL
```

## Chat

```chat
- 2026-07-18T05:06Z @claude (agent): Doc is live. Phase 0 ground truth is done; board is seeded from the local checklist (doc 08). Next up: gem scaffold, then Phase 1 transport + text. Ping me here to steer.
```
