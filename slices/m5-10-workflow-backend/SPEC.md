---
id: m5-10-workflow-backend
title: Execution backend for routines - routine.json v2, the native backend and its conformance suite, tool choice, scaffold, static validation and the workflow design rules lint, replay with held-out instances, deploy, rollback and drift
milestone: M5
status: ready
depends_on: [m1-05-routine-contract, m2-02-connections-catalog, m2-03-credential-broker, m5-03-model-router]
parallel_safe: false
human_gated: false
model_tier: sonnet
size: L
parallel_group: M5-C
owns: [packages/execution-backend/**, packages/routine-sdk/src/**, packages/routine-sdk/schemas/**, packages/routine-sdk/scripts/**, packages/testkit/src/execution-backend/**, packages/testkit/fixtures/execution-backend/**, packages/db/migrations/0510_execution_backend.sql, services/runtime/src/backends/**, services/api/src/routines/**, packages/contracts/src/routines/**]
verify: bash slices/m5-10-workflow-backend/verify.sh
min_tests: 60
paths_in_scope: [packages/execution-backend/**, services/api/src/builds/**, services/api/package.json, services/runtime/package.json, packages/routine-sdk/src/**, packages/routine-sdk/schemas/**, packages/routine-sdk/scripts/**, packages/routine-sdk/tests/m5-10-workflow-backend/**, packages/testkit/src/execution-backend/**, packages/testkit/fixtures/execution-backend/**, packages/db/migrations/0510_execution_backend.sql, packages/policy/src/rules/**, packages/contracts/src/routines/**, packages/contracts/src/briefs/**, packages/contracts/scripts/gen-json-schema.ts, packages/contracts/schemas/**, services/runtime/src/backends/**, services/api/src/routines/**, services/api/tests/m5-10-workflow-backend/**, slices/m5-10-workflow-backend/**, docs/API.md, docs/DATA_MODEL.md, docs/ARCHITECTURE.md, package.json, bun.lock]
paths_out_of_scope: [ee/**, apps/**, services/broker/**, services/brain/src/models/**, packages/masking/**, packages/db/src/**, packages/contracts/src/index.ts, packages/testkit/src/index.ts, docs/adr/**]
red_tests: [IR, SCAFFOLD, TOOLS, VALIDATE, RULES, REPLAY, HELDOUT, DEPLOY, ROLLBACK, DRIFT, BACKEND]
---

# m5-10-workflow-backend

## Summary
Builds the **execution backend** of [ADR 0040](../../docs/adr/0040-routine-definition-v2-and-execution-backends.md).
It takes one fix through every stage of that ADR and deploys it as a routine version:
1. tool choice (code ranks the candidate connectors);
2. code writes the scaffold `routine.json` from the brief;
3. static validation, including the lint of the eight workflow design rules (WF1 to WF8, ADR 0040 section 3.4);
4. replay of the visible instances through the native backend;
5. the held-out check over held-out instances, plus three back-office acceptance cases ([ACCEPTANCE.md](ACCEPTANCE.md))
   run by `evaluateCases` directly (they are golden cases, not output of `splitHeldOut`);
6. deploy bound to the approval hashes;
7. rollback, read-shape drift and the stability record.

It also adds the `ExecutionBackend` port and the **backend conformance suite** that any second backend must pass.
The owner called this "a workflow backend"; the glossary words are routine definition and execution backend
([GLOSSARY](../../docs/GLOSSARY.md)), so the package is `packages/execution-backend`.

Moves the M5 exit "he builds it through the same path as M2" ([ROADMAP M5](../../docs/ROADMAP.md#m5-observed-loop))
from one-off builds to versioned routines that survive tool changes. Implements:
- [ADR 0040](../../docs/adr/0040-routine-definition-v2-and-execution-backends.md) sections 1 to 6 and 8 (core rows only);
- the `routine.json` contract of [ADR 0026](../../docs/adr/0026-routine-artifact-contract.md), extended;
- the deploy binding of [ADR 0032](../../docs/adr/0032-deploy-approval-binds-definition.md);
- the pin rules of [ADR 0033](../../docs/adr/0033-pinned-connector-resolution-and-launch-catalog.md);
- [ARCHITECTURE section 11](../../docs/ARCHITECTURE.md#11-routine-runtime).

**Do not start before ROADMAP tasks m2-04, m2-05, m2-07, m2-09 and m2-10 are done.** They build fixture capture,
the brief, the build orchestrator, deploy and the runtime. They have no SPEC folders yet, so `depends_on` lists only
the specced slices this one also needs. Where this SPEC names a file those tasks create (the step interpreter, the
brief schema, `routine_versions`, `item_journal`, the routines routes), use the name they chose and record it under
"Scope changes". `paths_in_scope` allows the likely names only.

Open questions it builds on, with their defaults:
- [OQ-30](../../docs/OPEN_QUESTIONS.md#oq-30-n8n-in-offload), decided by the owner on 2026-11-22 ("Build worflow
  automation as an expert n8n engineer"): this slice builds the workflow design rules and their lint for the native
  routine definition. The n8n export, its lint and push are slice
  [m5-12-n8n-export](../m5-12-n8n-export/SPEC.md), which depends on this one. Nothing n8n-specific is built here.
- [OQ-31](../../docs/OPEN_QUESTIONS.md#oq-31-masked-text-fields-in-build-sandboxes): span tokenisation is ROADMAP task
  m5-11, not this slice. The acceptance fixtures here are synthetic and written already span-tokenised.

## Contract
**Package and dependencies.**
- New core package `packages/execution-backend` (`@offload/execution-backend`, `"license": "MIT"`), with source in
  `src/` and tests in `tests/m5-10-workflow-backend/`.
- No new external dependency. It uses `zod` 4.6.7 and `ajv` 8.20.0 (dev) as pinned in `packages/routine-sdk`,
  `@offload/contracts` (`jcs`, `sha256Hex`, `Figure`), `@offload/routine-sdk`, `@offload/policy` and
  `@offload/testkit` (dev). `pg` is pinned by m1-01 and used for the DEPLOY and ROLLBACK tests.

**`routine.json` v2** in `packages/routine-sdk`. v1 keeps parsing unchanged.
- zod schema `RoutineDefinitionV2`, exported to JSON Schema 2020-12 by the existing generator into
  `packages/routine-sdk/schemas/`. `additionalProperties: false` everywhere; `v: 2`.
- Per step (all optional in the document):
  - `retry: { max_attempts: int, interval_ms: int 250..60000, backoff_rate: number 1..4 }`;
  - `timeout_ms: int 100..300000`;
  - `on_error: "fail_run" | "skip_item"`.
- Commit steps only: `dedupe: { key: template, window_days: int 1..400 }`. `key` may reference only
  `{{ item.<field> }}`.
- `limits.max_skipped_items: int 0..500`, at most `max_items_per_run`, default 5.
- Class rules exactly as in [ADR 0040 section 1](../../docs/adr/0040-routine-definition-v2-and-execution-backends.md#1-routinejson-v2-is-the-ir)
  (allowed `max_attempts`, defaults, where `skip_item` is allowed; commit steps take no `retry`).
- `upgradeV1(def) → RoutineDefinitionV2` is pure.
- `resolveDefinitionV2(def, pins, readShapes)` is the only place defaults are filled: it writes each class default
  explicitly (commit steps get no `retry`), adds top-level `backend: "native"` and each `read` step's `read_shape`.
  `definitionHash` covers all of it. `parseRoutine` fills nothing.
- Schema-level rejections are zod errors whose issue `message` is the static validation code (`retry_not_allowed`,
  `skip_not_allowed`, `dedupe_invalid`); `validateStatic` reports the same codes, and `schema_invalid` for any other
  zod failure.
- A `read_shape` is a JSON Schema subset: `type`, `properties`, `required`, `items`, `anyOf`. At most 64 KiB as JCS.
  It never holds values.

**Brief fields**, added where m2-05 defined the brief schema (expected `packages/contracts/src/briefs/`):
- `item_identity: { [commit step id]: string[] }`: item fields. Required for every commit step (design rule WF5); a
  brief without it is refused with `dedupe_missing`;
- `parse_text: string[]`: JSON pointers into read outputs;
- `tool_choice: ToolChoice[]`.

**Port and native backend** (`packages/execution-backend/src/port.ts`):
```ts
interface ExecutionBackend {
  readonly id: string;                                        // "native"
  compile(def: ResolvedRoutineDefinitionV2, artifact: { artifact_sha256: string }): CompiledRoutine; // pure
  deploy(v: RoutineVersionRef): Promise<void>;
  startRun(v: RoutineVersionRef, trigger: TriggerEvent): Promise<{ run_id: string }>;
  retire(v: RoutineVersionRef): Promise<void>;
}
type CompiledRoutine = { backend: string; definition_hash: string; artifact_sha256: string; plan_hash: string; plan: unknown };
registerBackend(b: ExecutionBackend, opts: { conformance_passed: true }): void;  // the only way into allowedBackends()
```
- `plan` holds step ids, classes, hashes and policies, never connector values.
- The native backend (`services/runtime/src/backends/native.ts`) wraps the m2-10 runtime.
- Its step interpreter is `runRoutine(compiled, ports)` in `packages/routine-sdk`. All I/O goes through the injected
  `ports`: `{ connector, model, transforms, dedupe, clock }`. It **returns items, it never commits**.
- `RunResult` is `{ outcome, items, batch_hash, skipped[], deduped, retries, shape_violations[] }`:
  - `outcome` is `success`, `failed` or `capped`;
  - `skipped[]` entries are `{ step_id, element_hash, code }`;
  - `retries` maps step id to a count;
  - `shape_violations[]` entries are `{ step_id, pointer, expected, actual }`, where `expected` and `actual` are JSON
    type names, never values.
- `RunResult` is an in-memory value. In the native backend, read outputs and items go to m2-10's run content rows
  and durable steps return ids only ([ADR 0009](../../docs/adr/0009-durable-execution-on-postgres.md)).
- A step returns `null` for a `foreach` element to drop it (not counted) or `{ "$skip": "<code>" }` to skip it
  (counted, code `^[a-z_]{1,32}$`).
- Retries run inside the step with backoff on `ports.clock` ([ADR 0040 section 5](../../docs/adr/0040-routine-definition-v2-and-execution-backends.md#5-running-on-the-native-backend)).

**Pipeline functions** (`packages/execution-backend/src/`, all pure unless stated):
- `chooseTool(capability, candidates, stats) → ToolChoice`:
  - the rule ids and order are those of [ADR 0040 section 3.1](../../docs/adr/0040-routine-definition-v2-and-execution-backends.md#31-tool-choice-research-the-best-tools);
  - each rate is a `Figure` with arithmetic.
- `scaffold(brief) → RoutineDefinitionV2` and `lockedFields(def)`.
- `validateStatic(def, ctx) → Issue[]`:
  - `Issue = { code, pointer, rule? }`;
  - the codes are the list in [ADR 0040 section 3.3](../../docs/adr/0040-routine-definition-v2-and-execution-backends.md#33-static-validation);
  - it calls `lintRoutine` and returns its issues too.
- `lintRoutine(resolved, artifact, receipt?) → Issue[]` (`src/rules.ts`), the workflow design rules of
  [ADR 0040 section 3.4](../../docs/adr/0040-routine-definition-v2-and-execution-backends.md#34-workflow-design-rules):
  - every issue has `rule` (`wf.trigger`, `wf.single_purpose`, `wf.error_path`, `wf.retry_timeout`,
    `wf.idempotent`, `wf.credential_ref`, `wf.pinned_test`, `wf.heldout_gate`) and one of the codes in that table;
  - WF1 to WF7 run without a receipt; WF8 runs when a receipt is given, and `deployVersion` always gives one;
  - the rule ids and codes are exported as one constant, `WORKFLOW_DESIGN_RULES`, which slice m5-12 reuses for the
    n8n export, so both lints use the same ids;
  - limits: a transform module at most 150 non-blank lines, at most 20 steps;
  - WF6 reuses the secret-shaped value detector of the conformance suite (rule 2) and adds the credential-like key
    names `authorization`, `api_key`, `token`, `password`, `secret`, `cookie`.
- `deriveReadShape(outputs[]) → JSONSchema` and `checkReadShape(shape, output) → violations[]`.
- `splitHeldOut(instances, build_id) → { visible, held_out }`:
  - held out: 2 when n ≥ 6, 1 when n is 4 or 5, 0 when n ≤ 3;
  - order: lowest `sha256Hex(build_id + "\u0000" + instance_ref)` first.
- `buildWorkerBundle(fixtureSet, split)` returns visible instances only.
- `replay(compiled, artifact, fixtureSet) → { pass, items, batch_hash, mismatches[] }`.
  - It uses `fakeConnector` and a recorded-output fake model from `packages/testkit`.
  - Items are compared in token space by `item_hash`.
- `evaluateCases(compiled, artifact, caseSet) → { pass, cases[] }`:
  - a case is a sequence of runs with expected items, forbidden capabilities, expected `skipped` codes and expected
    `deduped` counts;
  - `checkTeeth(caseSet)` refuses a set in which no run expects an item (`no_teeth`).
- `deployVersion(db, { build_id, artifact_sha256, receipt_hash, definition_hash })` reads `backend` from the hashed
  resolved definition and writes through m2-09's routine version store, called from the existing deploy route
  `POST /v1/builds/{id}/deploy` (expected under `services/api/src/builds/`). It runs `lintRoutine` with the receipt
  first. Errors: `hash_mismatch` (403), `backend_not_allowed` (403), `heldout_not_passed` (403, WF8),
  `state_conflict` (409).
- `rollback(db, broker, { routine_id, to_version, artifact_sha256, receipt_hash, definition_hash })`:
  - it re-lists pins through `comparePins` (m2-02) first;
  - errors: `hash_mismatch`, `needs_review` (409, a pin changed), `state_conflict`.
- `stabilityRecord(runs, journal) → Figure[]`, with run ids as evidence.

**Policy.** New TypeScript rule `core.commit.opaque_ask` in `packages/policy/src/rules/`, next to m2-10's core rules
([ADR 0017](../../docs/adr/0017-policy-engine-cedar.md)): a commit through a connection with `opaque_workflow` asks,
even in `auto_commit`. If `packages/policy` is still a stub when this slice starts, add the rule as a pure function
with the same `rule_id` and record it under "Scope changes".

**Migration** `packages/db/migrations/0510_execution_backend.sql`:
- `routine_versions` gains `backend text NOT NULL DEFAULT 'native'` and `rolled_back_from int NULL`;
- `item_journal` gains `dedupe_hash text NULL` (already routine-scoped: `sha256(routine_id ‖ key)`), indexed on
  `(tenant_id, dedupe_hash)`;
- `circuit_breaker_trips.reason` accepts `read_shape_changed`;
- `connections` gains `opaque_workflow boolean NOT NULL DEFAULT false`, copied from the catalog entry at connect,
  or set by the user when they add their own MCP endpoint.

RLS stays as on the tables it extends.

**API** (contracts first in `packages/contracts/src/routines/`, then [API.md](../../docs/API.md), routes in
`services/api/src/routines/`):
- `POST /v1/routines/{id}/rollback { to_version, artifact_sha256, receipt_hash, definition_hash }` returns
  `201 { routine_id, version }`; errors `403 hash_mismatch`, `409 needs_review`, `409 state_conflict`.
- `GET /v1/routines/{id}` adds `backend` and `stability: Figure[]`.
- Audit action `routine.rolled_back`.
- Update [DATA_MODEL.md](../../docs/DATA_MODEL.md) and [ARCHITECTURE section 11](../../docs/ARCHITECTURE.md#11-routine-runtime)
  in the same commits.

**Fixtures.** `packages/testkit/fixtures/execution-backend/heldout/{a-invoice-bill,b-notes-crm,c-calendar-timesheet}.json`
encode [ACCEPTANCE.md](ACCEPTANCE.md):
- synthetic and tokenised (`tok_` + 12 hex);
- dates and enum values kept;
- no real names, emails or URLs with paths ([AGENTS.md](../../AGENTS.md#privacy-rules-for-agents)).

Each case ships with:
- a reference artifact (transforms and prompts) that must pass;
- the broken artifacts listed in ACCEPTANCE.md, each of which must fail.

## Red tests (write these first, run them, see them fail)
`status: ready` means the SPEC is complete; it still waits on the M2 tasks named in the Summary.

Folders:
- `packages/execution-backend/tests/m5-10-workflow-backend/`;
- `packages/routine-sdk/tests/m5-10-workflow-backend/` (IR);
- `services/api/tests/m5-10-workflow-backend/` (the DEPLOY and ROLLBACK route tests and the WF8 RULES test, real
  Postgres 17).

Tests never call a real model or service; model steps use the recorded-output fake.

| Tag | Test name | Asserts |
|---|---|---|
| IR | IR: a v1 routine upgrades to v2 with class defaults and the same steps | `upgradeV1` golden output |
| IR | IR: a retry policy on a commit step is rejected with retry_not_allowed | |
| IR | IR: a transform step with max_attempts above 1 is rejected | |
| IR | IR: skip_item is rejected outside a foreach and on commit steps with skip_not_allowed | |
| IR | IR: dedupe outside a commit step or with a key naming a non-item field is dedupe_invalid | `{{ steps.x.output/a }}` in a key fails |
| IR | IR: definition_hash changes when the backend, a retry policy, a dedupe key or a read shape changes | |
| IR | IR: generated v2 schemas are fresh and round-trip with zod | byte-identical regeneration |
| SCAFFOLD | SCAFFOLD: the same brief gives a byte-identical routine.json | JCS bytes equal over 3 calls |
| SCAFFOLD | SCAFFOLD: steps, capabilities, connections, trigger, limits and dedupe keys come from the brief only | golden per acceptance case |
| SCAFFOLD | SCAFFOLD: an artifact that changes a locked field fails with scaffold_changed | one per locked field kind |
| TOOLS | TOOLS: an unverified catalog entry is never chosen but a connection the user added and pinned is | rule `tool.unverified` recorded |
| TOOLS | TOOLS: a commit candidate without an argument allowlist is never chosen | `tool.no_allowlist` |
| TOOLS | TOOLS: a candidate failing above 10% over at least 20 calls is skipped and one at 19 calls is not | `tool.unstable`; boundary |
| TOOLS | TOOLS: verified candidates are ordered mcp, composio, openapi, browser | `tool.rung` |
| TOOLS | TOOLS: within one rung an existing connection wins, then wider capability coverage | `tool.connected`, `tool.coverage` |
| TOOLS | TOOLS: a model-named candidate that is in no catalog list is dropped | |
| TOOLS | TOOLS: every rate in the tool choice is a Figure with arithmetic | no number without arithmetic |
| VALIDATE | VALIDATE: a template path that the read shape does not have is unknown_field | |
| VALIDATE | VALIDATE: a capability or connection_ref outside the brief is refused | `capability_not_in_brief`, `connection_not_in_brief` |
| VALIDATE | VALIDATE: a model output schema with a number field is model_number | |
| VALIDATE | VALIDATE: a transform that does not load in the isolate is transform_invalid | |
| VALIDATE | VALIDATE: limits above the brief are limits_above_brief | |
| VALIDATE | VALIDATE: every issue has a code and a JSON pointer and no fixture value | canary token absent from issues |
| RULES | RULES: WF1 a routine with no trigger, two triggers or a schedule without a time zone is trigger_invalid | rule `wf.trigger` |
| RULES | RULES: WF2 a step with two capabilities, a transform over 150 non-blank lines or more than 20 steps is refused | `step_not_single_purpose`, `transform_too_large`, `too_many_steps` |
| RULES | RULES: WF3 a resolved step without an explicit on_error is error_path_missing | rule `wf.error_path` |
| RULES | RULES: WF4 a read, draft or model step without retry or timeout_ms is refused and a commit step with retry is retry_not_allowed | `retry_missing`, `timeout_missing` |
| RULES | RULES: WF5 a commit step without a dedupe key and a brief without item_identity are dedupe_missing | both |
| RULES | RULES: WF6 a literal secret or a credential-like key with a literal value in args, a template, a transform or a prompt is credential_inline | canary secret absent from the issue |
| RULES | RULES: WF7 a read or model step with no recorded output for the visible instances is pinned_test_missing | |
| RULES | RULES: WF8 deploy with a receipt whose held-out check or held-out instances did not pass is 403 heldout_not_passed and writes no version | real Postgres |
| RULES | RULES: the scaffold of each acceptance case and its reference artifact pass all eight rules | zero issues for cases A, B and C |
| RULES | RULES: every lint issue names one of the eight rule ids and a code from WORKFLOW_DESIGN_RULES and holds no fixture value | |
| REPLAY | REPLAY: the native backend replays the visible instances and its items equal the expected items | acceptance case A |
| REPLAY | REPLAY: replaying the same fixture set twice gives the same batch_hash | |
| REPLAY | REPLAY: a read that fails twice with 503 then succeeds counts 2 retries on the fake clock | backoff 1 s then 2 s |
| REPLAY | REPLAY: a commit step has no retry and its items are returned, never sent | |
| REPLAY | REPLAY: skip_item sets one element aside and the run fails with no items when skips exceed max_skipped_items | failed run returns zero items |
| REPLAY | REPLAY: an item whose dedupe key is pending or sent from an earlier run within the window is dropped and counted | pending case: run 1 batch not yet approved |
| REPLAY | REPLAY: runRoutine never calls a connector commit | fake connector commit spy is 0 |
| HELDOUT | HELDOUT: splitHeldOut holds out 2 of 8, 1 of 5, 1 of 4 and none of 3, deterministically per build | |
| HELDOUT | HELDOUT: two builds of the same brief draw different splits | |
| HELDOUT | HELDOUT: the worker bundle never contains a held-out instance | canary token in held-out instances |
| HELDOUT | HELDOUT: case A passes the reference artifact and fails each broken artifact | [ACCEPTANCE.md](ACCEPTANCE.md) case A |
| HELDOUT | HELDOUT: case B passes the reference artifact and fails each broken artifact | case B |
| HELDOUT | HELDOUT: case C passes the reference artifact and fails each broken artifact | case C |
| HELDOUT | HELDOUT: a case set in which no run expects an item is refused as no_teeth | also: a step returning `$skip` is counted, `null` is not |
| DEPLOY | DEPLOY: deploy binds artifact_sha256, receipt_hash and definition_hash with backend native and starts ask_before_commit | real Postgres |
| DEPLOY | DEPLOY: any hash mismatch is 403 hash_mismatch and writes no version | |
| DEPLOY | DEPLOY: a backend not registered as passing the conformance suite is 403 backend_not_allowed | |
| ROLLBACK | ROLLBACK: rolling back from version 2 to version 1 creates version 3 with rolled_back_from 1, ask_before_commit and streak 0 | audit `routine.rolled_back` |
| ROLLBACK | ROLLBACK: a changed pin on the target version is 409 needs_review and writes no version | |
| DRIFT | DRIFT: a read missing a required key puts the routine in needs_review with read_shape_changed and commits nothing | breaker row |
| DRIFT | DRIFT: an extra key or a missing optional key is not drift | |
| DRIFT | DRIFT: the stability record counts runs, items, skips, dedupes and retries with arithmetic and run ids | golden Figures |
| DRIFT | DRIFT: a commit through an opaque_workflow connection asks even in auto_commit | rule `core.commit.opaque_ask` |
| BACKEND | BACKEND: the native backend passes the conformance suite | all 8 rules of ADR 0040 section 2 |
| BACKEND | BACKEND: a test backend that commits without an approved item hash fails the suite | |
| BACKEND | BACKEND: a test backend whose compiled routine holds a secret-shaped value fails the suite | |
| BACKEND | BACKEND: a test backend that writes fixture text into durable state fails the suite | |

## Out of scope
- **Span tokenisation of `parse_text` fields.** That is ROADMAP task m5-11 after
  [OQ-31](../../docs/OPEN_QUESTIONS.md#oq-31-masked-text-fields-in-build-sandboxes).
- **Changes to the model router** (m5-03).
- **Any n8n code, the n8n export, its lint or push, or a third-party backend.** The export is slice
  [m5-12-n8n-export](../m5-12-n8n-export/SPEC.md) ([OQ-30](../../docs/OPEN_QUESTIONS.md#oq-30-n8n-in-offload)); this
  slice only exports `WORKFLOW_DESIGN_RULES` for it.
- **Spike S8** (porting one Activepieces piece).
- **The public list refresh job for tool candidates.** Candidates come in as data here.
- **Web and Mac screens** for rollback and the stability record (M8 web, M5 Mac tasks).
- **EE rows of ADR 0040 section 8**: teams sharing, N-of-M deploy approvals, SIEM.
- **Wiring outside the paths in scope.** Calling `splitHeldOut` and `deriveReadShape` from fixture capture, and
  `validateStatic`, `replay` and `evaluateCases` from the verification sandbox, are one-line call-site changes in the
  m2-04 and m2-07 code. If those files are outside `paths_in_scope`, widen it under "Scope changes" in the same
  commit.

## Verify
`bash slices/m5-10-workflow-backend/verify.sh`. It needs `DATABASE_URL` (Postgres 17, a disposable `*_test`
database) for the DEPLOY and ROLLBACK tests.
- Typecheck.
- The slice suite has at least `min_tests` tests and every tag is present and passing.
- The full suite passes.
- Every change since `BASE` matches `paths_in_scope` and none matches `paths_out_of_scope`.

`min_tests`, `red_tests` and both path lists are read from this front-matter. `BASE` is required once
`status: in_progress`.

## Scope changes
None.
