---
id: m1-05-routine-contract
title: Routine artifact contract in packages/routine-sdk - routine.json schema, definition_hash, pure transform isolate, manifest checks, and the testkit fake connector
milestone: M1
status: done
depends_on: [m1-02-contracts-ingest]
parallel_safe: false
human_gated: false
model_tier: sonnet
size: M
parallel_group: M1-C
owns: [packages/routine-sdk/**]
verify: bash slices/m1-05-routine-contract/verify.sh
min_tests: 20
paths_in_scope: [packages/routine-sdk/**, packages/testkit/**, slices/m1-05-routine-contract/**, docs/API.md, package.json, bun.lock, slices/m5-03-model-router/**, services/brain/src/models/**, services/brain/config/**, services/brain/tests/m5-03-model-router/**, services/brain/package.json, packages/masking/src/names/**, packages/masking/tests/m5-03-model-router/**, docs/ARCHITECTURE.md]
paths_out_of_scope: [ee/**, apps/**, services/api/**, services/broker/**, services/builder/**, services/runtime/**, packages/db/**, packages/contracts/src/**, docs/adr/**]
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
- **Spike S7 result**: `quickjs-emscripten` 0.32.0 kept. QuickJS's own `setMemoryLimit` does not bound total heap in
  this build (it cannot measure allocation sizes, so many 1 MiB buffers pass it), so each `runTransform` call gets its
  own QuickJS WebAssembly instance whose `WebAssembly.Memory` is capped at 64 MiB (engine included); the deadline is an
  interrupt handler at 1 s (measured about 1.02 s). About 4 ms per call. `loadTransform(source)` is the deploy check
  "every transform loads in the isolate". Errors: `transform_timeout`, `transform_memory`, `transform_error`,
  `transform_invalid`.
- **Template grammar made exact**: the JSON pointer follows `output` directly, `{{ steps.<id>.output/data/0/amount }}`
  (the SPEC's `output.<json pointer>` would put a dot before a pointer that already starts with `/`). A string that is
  exactly one reference keeps the referenced JSON type; references inside text join strings, numbers and booleans.
- **Resolved steps also carry `provider` and `account_label`**, because ADR 0032 puts "which account" into the hashed
  definition and `describeDefinition` names it. `Item` also carries `item_hash`; `item_key` is
  `<step id>/sha256Hex(JCS(foreach element))` (of the rendered args without foreach).
- **Model step refs**: `prompt_ref` under `prompts/*.md`, `output_schema_ref` under `schemas/*.json`.
- `ajv` 8.20.0 (dev, same pin as `packages/contracts`) added for the JSON Schema round-trip tests.
- Two red tests were corrected after the red commit because the tests were wrong, not the code: the planCommit
  expectation (a whole-string reference keeps the number) and the 64 MiB string case (QuickJS builds `s + s` as ropes
  and hits a length limit first). Cases were added, not removed.
- Done (2026-11-15), scope widened for the interleaved m5-03-model-router commits. m5-03 was built on the same branch
  after this slice's BASE and history is not rewritten, so its files (`services/brain/src/models/**`,
  `services/brain/config/**`, its tests, `services/brain/package.json`, `packages/masking/src/names/**` and its tests,
  `docs/ARCHITECTURE.md`, `slices/m5-03-model-router/**`) are listed in `paths_in_scope`, and `services/**` in
  `paths_out_of_scope` is narrowed to the services this slice and m5-03 do not touch. m5-03 has its own scope check.
