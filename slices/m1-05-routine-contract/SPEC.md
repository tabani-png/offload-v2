---
id: m1-05-routine-contract
title: Routine artifact contract in packages/routine-sdk - routine.json schema, definition_hash, pure transform isolate, manifest checks, and the testkit fake connector
milestone: M1
status: ready
depends_on: [m1-02-contracts-ingest]
parallel_safe: false
human_gated: false
model_tier: sonnet
size: M
parallel_group: M1-C
owns: [packages/routine-sdk/**]
verify: bash slices/m1-05-routine-contract/verify.sh
min_tests: 20
paths_in_scope: [packages/routine-sdk/**, packages/testkit/**, slices/m1-05-routine-contract/**, docs/API.md, package.json, bun.lock]
paths_out_of_scope: [ee/**, apps/**, services/**, packages/db/**, packages/contracts/src/**, docs/adr/**]
red_tests: [ROUTINE, TRANSFORM, FAKE]
---

# m1-05-routine-contract

## Summary
Defines what a build produces and what the runtime runs, before the first build in [M2](../../docs/ROADMAP.md#m2-hand-fed-loop).
Implements [ADR 0026](../../docs/adr/0026-routine-artifact-contract.md) and the step placement field from
[ADR 0025](../../docs/adr/0025-execution-placement-and-mac-actuator.md); `definition_hash` is the value the deploy
approval binds ([ADR 0032](../../docs/adr/0032-deploy-approval-binds-definition.md)). Checks, replay fixtures and the
fake connector all target this SDK ([ARCHITECTURE section 11](../../docs/ARCHITECTURE.md#11-routine-runtime)). Runs
spike S7 (transform isolate). Part of [M1](../../docs/ROADMAP.md#m1-foundations).

## Contract
- Delete `packages/routine-sdk/tests/smoke.test.ts` and `packages/testkit/tests/smoke.test.ts` (the TODO markers are
  replaced).
- Dependencies (exact pins): `zod` (same exact version as `packages/contracts`), `@offload/contracts` (workspace, for
  `jcs`, `sha256Hex`), and the transform isolate chosen by spike S7: candidate `quickjs-emscripten` (MIT). If S7 rejects
  it, record the replacement under "Scope changes".
- `routine.json` schema `RoutineDefinition` (zod, exported to JSON Schema 2020-12 by a generator in
  `packages/routine-sdk/scripts/gen-json-schema.ts`, committed under `packages/routine-sdk/schemas/`), `additionalProperties:
  false` everywhere:
  ```
  { v: 1, name (≤ 80),
    trigger: { kind: "schedule" | "webhook" | "event" | "manual", cron? (5-field), timezone? (IANA), event_type? },
    steps: [{ id (^[a-z][a-z0-9_]{0,31}$, unique), class: "read" | "draft" | "commit" | "transform" | "model",
              runs_on: "cloud" | "device", capability? , connection_ref?, args (template object), foreach? (step id),
              transform? (path under transforms/), model?: { route, prompt_ref, output_schema_ref } }],
    limits: { max_items_per_run (1..500), max_runs_per_day (1..96), run_budget_usd (≤ 4.00),
              quiet_hours?: { start: "HH:MM", end: "HH:MM" } | null, recipients_from?: step id },
    capabilities: [capability] }
  ```
  Rules: `read`, `draft`, `commit` need `capability` and `connection_ref`; `transform` needs `transform` and no
  capability; `model` needs `model`, has no capability and no tools; `runs_on: "device"` is allowed only for `commit`
  steps whose capability is in the device set (`shortcut.run`, `appleevent.template`, `ax.action`, `browser.step`);
  `foreach` must name an earlier step; every step capability is listed in `capabilities`.
- **Templates**: `args` values are strings with `{{ steps.<id>.output.<json pointer> }}` or `{{ item.<field> }}`
  references only. No expressions, no code. `renderArgs(template, scope)` is pure.
- **Commit steps return items**: `planCommit(step, scope) → Item[]` where `Item = { item_key, capability,
  connection_ref, args }` and `item_hash = sha256Hex(jcs({ capability, connection_ref, args }))`. The SDK has no
  function that performs I/O; the runtime and the broker do.
- **Transforms**: modules under `transforms/*.ts`, `export default function (input: unknown): unknown`, compiled to JS
  at build time and run in the isolate with no host functions except the input: no `fetch`, no timers, no `require`,
  memory 64 MiB, time 1 s. `runTransform(source, input)`.
- **Definition hash**: `resolveDefinition(def, pins)` fills each step's `connection_id`, `adapter`, `tool_name`,
  `tool_pin_hash` from the brief's pinned connections; `definitionHash(resolved) = sha256Hex(jcs(resolved))`.
  `describeDefinition(resolved)` returns the plain-words lines the deploy screen shows (trigger, each step's
  capability and account label, limits).
- **Manifest checks**: `checkManifest(def, brief)` fails unless `def.capabilities ⊆ brief.capabilities` and every
  `connection_ref ⊆ brief.connections`.
- **Fake connector** in `packages/testkit` (`fakeConnector(fixtureSet)`): serves recorded reads keyed by
  `(capability, args hash)`, records commit items without executing them, and fails the test on any read it has no
  recording for. Fixture values are tokenised (`tok_` + 12 hex) as in
  [ADR 0027](../../docs/adr/0027-fixture-capture-and-connector-content.md).

## Red tests
Folder: `packages/routine-sdk/tests/m1-05-routine-contract/` (FAKE tests in `packages/testkit/tests/m1-05-routine-contract/`;
the verify script runs both folders).

| Tag | Test name | Asserts |
|---|---|---|
| ROUTINE | ROUTINE: a valid routine.json round-trips zod ↔ JSON Schema 2020-12 | |
| ROUTINE | ROUTINE: generated routine schemas are fresh | byte-identical regeneration |
| ROUTINE | ROUTINE: unknown fields anywhere are rejected | |
| ROUTINE | ROUTINE: a commit step without capability or connection_ref is rejected | |
| ROUTINE | ROUTINE: a model step with a capability is rejected | model steps are tool-less |
| ROUTINE | ROUTINE: runs_on device is rejected for read, draft and non-device capabilities | |
| ROUTINE | ROUTINE: foreach must name an earlier step | |
| ROUTINE | ROUTINE: a template with an expression is rejected | `{{ 1 + 1 }}`, `{{ item.a || x }}` fail |
| ROUTINE | ROUTINE: planCommit returns items with item_hash over JCS and performs no I/O | `fetch` patched to throw |
| ROUTINE | ROUTINE: definitionHash changes when a connection_id or tool pin changes | |
| ROUTINE | ROUTINE: describeDefinition names the account and limits for every step | golden text |
| ROUTINE | ROUTINE: checkManifest refuses a capability not in the brief | |
| ROUTINE | ROUTINE: run_budget_usd above 4.00 is rejected | |
| TRANSFORM | TRANSFORM: a pure transform maps input to output | |
| TRANSFORM | TRANSFORM: fetch, require and timers are not defined inside the isolate | |
| TRANSFORM | TRANSFORM: a transform over 1 second is stopped | |
| TRANSFORM | TRANSFORM: a transform over 64 MiB is stopped | |
| FAKE | FAKE: recorded reads are replayed by capability and args hash | |
| FAKE | FAKE: commit items are recorded and never executed | |
| FAKE | FAKE: a read with no recording fails the test | |

## Out of scope
The routine runtime, the broker, real connectors, the build orchestrator (M2), device execution (M6).

## Verify
`bash slices/m1-05-routine-contract/verify.sh`.

## Scope changes
None.
