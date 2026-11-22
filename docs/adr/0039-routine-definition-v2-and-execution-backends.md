# 0039. Fixes as versioned routine definitions on pluggable execution backends

Status: proposed (review pending). [OQ-30](../OPEN_QUESTIONS.md#oq-30-n8n-in-offload) was decided by the owner on
2026-11-22 (sections 3.4, 7 and 9); pushing to a user's n8n is built but switched off until
[OQ-32](../OPEN_QUESTIONS.md#oq-32-written-license-confirmation-from-n8n); span tokenisation waits on
[OQ-31](../OPEN_QUESTIONS.md#oq-31-masked-text-fields-in-build-sandboxes) · Date: 2026-11-22 ·
Extends [ADR 0026](0026-routine-artifact-contract.md) (`routine.json` v2), [ADR 0027](0027-fixture-capture-and-connector-content.md)
(held-out instances, read shapes) and [ADR 0033](0033-pinned-connector-resolution-and-launch-catalog.md) (tool choice)

## Context
The owner asked, verbatim: "it should give well designed workflows maybe even through like n8n to automate things
... we need stable workflows that are built and it needs to research the best tools to make those but n8n may allow
that to happen faster".

**The owner's decision on n8n** ([OQ-30](../OPEN_QUESTIONS.md#oq-30-n8n-in-offload), 2026-11-22), verbatim:
"Build worflow automation as an expert n8n engineer". It means three things here:
1. the fix designer and every routine definition follow expert n8n practice, written as eight testable workflow
   design rules (section 3.4);
2. Offload can export a verified fix as import-ready n8n workflow JSON for the user's own n8n, and push it there
   through that instance's public API when the user connects it (section 9);
3. Offload's own engine stays the default runtime; n8n run by Offload for users stays gated on n8n's written
   license confirmation ([OQ-32](../OPEN_QUESTIONS.md#oq-32-written-license-confirmation-from-n8n)).

**What exists.**
- A fix is a routine artifact: `routine.json` plus pure transforms ([ADR 0026](0026-routine-artifact-contract.md)).
  `routine.json` v1 is built and tested (slice `m1-05-routine-contract`).
- The routine runtime that runs it on DBOS Transact ([ADR 0009](0009-durable-execution-on-postgres.md)) is M2 task
  m2-10, not yet specced.
- Connectors are chosen and pinned at design time in the order MCP, Composio, direct API, browser
  ([ADR 0033](0033-pinned-connector-resolution-and-launch-catalog.md)).

**The research.** [Workflow engines for Offload fixes](../research/workflow-engines-2026-11.md), checked 2026-11-22,
found:
- **n8n's license forbids Offload's use case on n8n that Offload runs.** Its FAQ does not allow letting "external end
  users ... build or configure their own workflows through your product, whether via a custom UI, our API, MCP, or an
  AI agent acting on the user's behalf". Doing it needs an OEM or Enterprise agreement.
- **n8n, Activepieces and Windmill hold the credentials and make the outbound call themselves.** As execution
  backends they would bypass the gate, the item journal and the broker
  ([ADR 0004](0004-every-external-action-is-gated.md), [ADR 0034](0034-credential-broker-and-key-providers.md)).
- **Temporal** is MIT and strong, but it is a cluster to self-host, which [ADR 0009](0009-durable-execution-on-postgres.md)
  already declined.
- **Scored matrix**: the native backend 91 of 100, Temporal 67, three engine options 59, n8n hosted by Offload 47.

**What v1 lacks for "stable".**
1. No per-step retry policy or timeout.
2. No rule for one bad element in a `foreach`: it either fails the whole run or is undefined.
3. Duplicate protection is implicit in `item_key`. An invoice email whose labels change gets a new key and could be
   billed twice.
4. Drift is detected only for tool pins, not for a connector that changes the shape of what it returns.
5. No rollback.
6. The worker writes the whole definition, so the step graph is invented again on every build.
7. Every captured instance is shown to the worker, so replay tests fit rather than generalise.
8. Every connector string becomes one opaque token ([ADR 0027](0027-fixture-capture-and-connector-content.md)), so a
   fix that must parse a mail body or a notes document cannot be built against its fixtures.

**Words.** In the glossary, "workflow" is a durable runtime execution ([ADR 0009](0009-durable-execution-on-postgres.md)).
What the owner calls "a workflow" is a **routine**, whose definition is `routine.json`. This ADR adds no second
artifact: the routine definition is the backend-neutral IR. The ask's "dry-run" and "dry validation" are
**replay** and **static validation** here ([ADR 0016](0016-no-dry-run.md)).

## Decision

### 1. `routine.json` v2 is the IR
- `routine.json` gains version 2 (schema in `packages/routine-sdk`, zod, JSON Schema 2020-12, `additionalProperties:
  false`). New fields are optional in the document. `resolveDefinitionV2` (the one filler) writes the class defaults
  explicitly, so the hash binds them; commit steps never get a `retry`:
  - per step: `retry: { max_attempts, interval_ms, backoff_rate }`, `timeout_ms`,
    `on_error: "fail_run" | "skip_item"`;
  - per commit step: `dedupe: { key, window_days }`. `key` is a template over `{{ item.* }}` fields only, for example
    `{{ item.vendor_ref }}:{{ item.invoice_number }}`. Optional in the schema so v1 upgrades parse, but required by
    design rule WF5 (section 3.4) for anything built or deployed;
  - in `limits`: `max_skipped_items` (default 5, at most `max_items_per_run`);
  - in the **resolved** definition only (filled at deploy like the pins): `backend` (`"native"`) and, per `read`
    step, `read_shape` (section 4).
- **Class rules** (static validation refuses anything else):

  | Class | Retry default | `max_attempts` allowed | Timeout default | `on_error` allowed |
  |---|---|---|---|---|
  | `read` | 3 attempts, 1 s, ×2 | 1 to 5 | 30 s | `fail_run`; `skip_item` inside a `foreach` |
  | `draft` | 3 attempts, 1 s, ×2 | 1 to 5 | 30 s | `fail_run`; `skip_item` inside a `foreach` |
  | `model` | 2 attempts, 2 s, ×2, on provider overload only (escalation stays the router's, [ADR 0021](0021-model-router-and-builders.md)) | 1 to 3 | 120 s | `fail_run`; `skip_item` inside a `foreach` |
  | `transform` | 1 (a pure function gives the same answer twice) | 1 | 1 s (the isolate's limit) | `fail_run`; `skip_item` inside a `foreach` |
  | `commit` | none | 1 | 30 s; a timeout makes the item `unknown` | `fail_run` only: a failed item is an item journal outcome, not a step error |

  `interval_ms` is 250 to 60 000 and `backoff_rate` is 1 to 4.
- **Linear by design.** Steps run in order with `foreach` as the only loop. There are no branches, no expressions and
  no error routes. Conditions and filtering are transforms: they are pure, tested and readable. That keeps every
  definition describable in words for the deploy approval ([ADR 0032](0032-deploy-approval-binds-definition.md)) and
  checkable by code.
- **v1 stays valid.** Deployed v1 versions keep running as v1 with their own `definition_hash`; nothing is re-hashed.
  New builds write v2. `upgradeV1(def)` is pure and fills class defaults.
- **Backend-neutral.** The plain definition names no backend. The resolved definition names one (`backend`), so the
  deploy approval binds where it runs. The backend's own version is not in the hash: release-to-release behaviour is
  the conformance suite's job (section 2).

### 2. Execution backends behind a port
- `packages/execution-backend` (core) defines the **`ExecutionBackend` port**:
  - `id`;
  - `compile(resolved, artifact) → CompiledRoutine`: pure, ids and hashes only, no secrets;
  - `deploy(version)`;
  - `startRun(version, trigger) → run_id`;
  - `retire(version)`.

  It also holds the **backend conformance suite**, static validation, replay, held-out evaluation, deploy and
  rollback, drift checks and the stability record.
- **`native` is the default and the only backend in the core distribution**: the routine runtime (`services/runtime`)
  on the durable runtime. The step interpreter lives in `packages/routine-sdk`, pure, with all I/O through an
  injected connector port. Replay, held-out evaluation and live runs therefore execute the same code.
- **A backend may run a routine only if it passes the conformance suite** in CI for the release that runs it:
  1. it never makes a commit call itself; commit items reach the gate, and with no approval and no policy allow,
     zero commit calls reach any connector;
  2. no credential or secret-shaped value appears in a compiled routine, its durable state or its logs (canary
     test, [ADR 0035](0035-mac-egress-guard-and-ledger.md));
  3. an item journal row is written before every commit call; a crash after sending leaves the item `unknown`, never
     re-sent;
  4. durable state holds ids and hashes only ([ADR 0009](0009-durable-execution-on-postgres.md));
  5. tool pins are re-listed before each run and a change gives `needs_review`;
  6. read shapes are checked on every read and a violation gives `needs_review` with nothing committed;
  7. the golden acceptance cases of slice `m5-10-workflow-backend` give the same batch hashes as the native
     interpreter;
  8. a kill switch stops commits within one step.

  A deploy that names a backend not registered as passing is refused (`backend_not_allowed`).
- **Engines that hold credentials and call apps themselves cannot pass rules 1 to 3.** n8n, Activepieces and
  Windmill reach Offload only as **integration sources** (section 7), never as backends. A backend adapter for a
  third-party engine that needs a commercial agreement with that engine's vendor lives in `ee/` and ships only with
  that agreement. None is planned.

### 3. How a fix becomes a routine version

| # | Stage | Who | Output | Checked by |
|---|---|---|---|---|
| 1 | Tool choice | fix designer: code ranks, a model may only name candidates | `tool_choice` in the brief | code (section 3.1) |
| 2 | Connect and pin | user, fix designer | connection pins | [ADR 0033](0033-pinned-connector-resolution-and-launch-catalog.md) |
| 3 | Fixture capture | fix designer, gate mode `read` | visible instances, held-out instances, read shapes | section 4 |
| 4 | Brief and scaffold | Opus writes the brief; **code** writes the skeleton `routine.json` from it | `brief_hash`; scaffold | section 3.2 |
| 5 | Build | Sonnet worker in a sandbox fills args, transforms, prompts and output schemas | artifact | [ADR 0012](0012-builder-policy-one-worker-held-out-fan-out.md) |
| 6 | Static validation and design-rule lint | code | issue list; any issue fails the attempt like a check failure | sections 3.3 and 3.4 |
| 7 | Verification | fresh sandbox | frozen checks; replay of visible instances; held-out check over the held-out instances | [ADR 0029](0029-build-verdicts.md) |
| 8 | Verifier, receipt | Opus; code signs | `receipt_hash` | [ADR 0012](0012-builder-policy-one-worker-held-out-fan-out.md) |
| 9 | Deploy approval | user | binds `artifact_sha256`, `receipt_hash`, `definition_hash` (with `backend`, retry policies, dedupe keys and read shapes inside) | [ADR 0032](0032-deploy-approval-binds-definition.md); WF8 |
| 9a | n8n export (optional, instead of or besides step 10) | code; the user downloads it, or approves a push that also binds `export_hash` | n8n workflow JSON for the user's own n8n | section 9 |
| 10 | Run | native backend | items through the gate and the broker | section 5 |
| 11 | Watch | code | drift, stability record | section 6 |
| 12 | Change | user | rollback or repair | section 6 |

#### 3.1 Tool choice ("research the best tools")
- **Candidates per capability** come from data:
  - the launch catalog ([ADR 0033](0033-pinned-connector-resolution-and-launch-catalog.md));
  - the tenant's existing connections;
  - the MCP Registry (preview; metadata only);
  - Composio's toolkit list;
  - vendor OpenAPI descriptions;
  - MCP endpoints the user adds, including their own n8n or Activepieces.

  A job refreshes the public lists. A model on the `design` route may name candidates, but only names found in those
  lists are kept.
- **Code decides, in this order**, each step recording its rule id:
  1. drop entries not verified in the catalog (`tool.unverified`); a newly found candidate enters the catalog
     unverified, and verification works as in spike S5. A connection the user added and pinned themselves (for
     example their own n8n MCP endpoint) counts as verified for that user;
  2. drop commit candidates without an argument allowlist (`tool.no_allowlist`);
  3. drop candidates whose failure rate in this tenant is above 10% over at least 20 calls in the last 30 days
     (`tool.unstable`; counts from the item journal and run records, no content);
  4. order by rung: MCP, Composio, direct API, browser (`tool.rung`, [ADR 0010](0010-mcp-first-connectors.md));
  5. prefer an existing connection (`tool.connected`);
  6. prefer the candidate that covers more of the brief's capabilities with one connection (`tool.coverage`).
- The record (candidates, rule ids, every rate with its arithmetic) is part of the brief and its hash. It is shown in
  words, for example: "Bills go to Xero through Composio. Xero's MCP server is not verified yet." Numbers in it come
  from code ([ADR 0003](0003-numbers-come-from-code.md)).

#### 3.2 Scaffold: code writes the graph, the worker writes the code
- `scaffold(brief)` is deterministic: the same brief always gives a byte-identical skeleton.
- From the brief it fills: trigger, step ids, classes, `runs_on`, capabilities, `connection_ref`s, `foreach`, limits,
  class-default retry and timeout, and each commit step's dedupe key. The key comes from a new brief field,
  `item_identity` (the fields that make two items the same thing, for example vendor and invoice number).
- The worker may change only `args`, the contents of transform modules, prompts and output schemas, and `on_error` on
  non-commit steps within the class rules. A change to any other field is the static validation issue
  `scaffold_changed`.
- The step graph is therefore decided once, in code, from what the user approved.

#### 3.3 Static validation
Code, before any replay. Each issue carries a code and a JSON pointer, never a connector value:
- `schema_invalid`;
- `scaffold_changed`;
- `capability_not_in_brief`;
- `connection_not_in_brief` (the code `checkManifest` already uses);
- `unknown_field`: a template points at a path the read shape or the model output schema does not have;
- `transform_invalid`: a transform does not load in the isolate;
- `retry_not_allowed`;
- `skip_not_allowed`;
- `dedupe_invalid`;
- `model_number`: a model output schema has a number field, which the router would refuse anyway
  ([ADR 0003](0003-numbers-come-from-code.md), m5-03);
- `limits_above_brief`;
- `backend_not_allowed`;
- the design-rule codes of section 3.4.

#### 3.4 Workflow design rules
The owner's "as an expert n8n engineer", as rules code can check. They apply to the native routine definition and to
the n8n export (section 9) alike. Each rule has an id and issue codes. `lintRoutine(resolved, artifact, receipt?)`
(in `packages/execution-backend`) checks WF1 to WF7 inside static validation and WF8 at deploy;
`lintN8nExport(bundle, catalog)` (in `packages/n8n-export`) checks the same rules on an export. An issue is
`{ code, rule, pointer }` with no connector value. Any issue refuses the definition or the export; there is no
override.

| Rule | Native routine definition | n8n export | Issue codes |
|---|---|---|---|
| **WF1 Explicit trigger** (`wf.trigger`) | Exactly one trigger: `schedule` (cron and an IANA time zone, never a default zone), `manual`, `webhook` or `event` | Exactly one trigger node (Schedule Trigger with a five-field cron expression, Manual Trigger or Webhook) and `settings.timezone` set to the trigger's zone; n8n otherwise falls back to the instance zone, `America/New York` by default. The error workflow has exactly one Error Trigger | `trigger_invalid` |
| **WF2 Small, single-purpose steps** (`wf.single_purpose`) | Each step has one class, at most one capability and one `connection_ref`. A transform module exports one function and has at most 150 non-blank lines. At most 20 steps. Step ids are unique `snake_case` | One node per step, plus only the helper nodes section 9.2 names (split, skip check, skipped-items, model output check, Remove Duplicates). Node names are unique and come from the step ids; each node's `notes` holds that step's sentence from the definition in words | `step_not_single_purpose`, `transform_too_large`, `too_many_steps` |
| **WF3 Error workflow and error branches** (`wf.error_path`) | Every step's `on_error` is explicit in the resolved definition. The element-level error branch is `skip_item` with a code; the run-level error path is the runtime's (a failed run commits nothing, the breaker counts it, the member sees it). The IR stays linear: no error routes (section 1) | `settings.errorWorkflow` names the companion error workflow in the same export (Error Trigger, then one notification node), which is published whenever the main workflow is. A `skip_item` step's node has `onError: "continueErrorOutput"` with its error output wired to the skipped-items node; every other node has `onError: "stopWorkflow"`. No node uses `continueRegularOutput` or the deprecated `continueOnFail` | `error_path_missing` |
| **WF4 Per-step retries and timeouts** (`wf.retry_timeout`) | Every `read`, `draft` and `model` step has an explicit `retry` and `timeout_ms` inside the class rules; commit steps have `timeout_ms` and no `retry` (section 1) | Those nodes set `retryOnFail: true`, `maxTries` and `waitBetweenTries` from the retry policy; commit nodes set `retryOnFail: false`. HTTP Request nodes set their Timeout option (milliseconds) from `timeout_ms`; `settings.executionTimeout` bounds the run. n8n waits a fixed time between tries, so `backoff_rate` is not carried over and the export card says so | `retry_missing`, `retry_not_allowed`, `timeout_missing` |
| **WF5 Idempotent writes** (`wf.idempotent`) | Every commit step has a `dedupe` key, written by the scaffold from the brief's `item_identity`. A brief without `item_identity` for a commit step is refused | A Remove Duplicates node ("Remove Items Processed in Previous Executions", scope Workflow, value the rendered dedupe key) directly before each commit node | `dedupe_missing` |
| **WF6 Credentials by reference only** (`wf.credential_ref`) | Steps name a `connection_ref` only. No secret-shaped value (the canary detector of [ADR 0035](0035-mac-egress-guard-and-ledger.md)) and no literal value under a credential-like key (`authorization`, `api_key`, `token`, `password`, `secret`, `cookie`) in args, templates, transforms or prompts | Each node's `credentials` gives a credential type and a placeholder name from the export's credential map, never an `id` or a value. No literal Authorization header, query key or body field. n8n warns that exported JSON can carry credential names and ids and cURL-imported auth headers; an Offload export carries none | `credential_inline` |
| **WF7 Pinned-data test runs** (`wf.pinned_test`) | Every `read` and `model` step has recorded outputs for the visible instances, and replay passes (stage 7) | `pinData`, keyed by node name, holds the tokenised visible-instance outputs of the trigger, every read node and every model node, and the expected items of every Remove Duplicates and commit node, so a test run in the n8n editor writes nothing; the export's pinned-data test passes (sections 9.3 and 9.4) | `pinned_test_missing`, `pinned_test_failed`, `pinned_shape_mismatch` |
| **WF8 Held-out acceptance before activation** (`wf.heldout_gate`) | Deploy is refused unless the receipt records a passing held-out check and, when instances were held out, passing held-out instances ([ADR 0029](0029-build-verdicts.md)) | An export is made only from such a receipt, and the held-out instances must also pass the export's pinned-data test (on Offload's data; section 9.3 says what that does not cover). The file is never published on import; a push publishes only when its approval says so | `heldout_not_passed` |

Two n8n limits are stated, not hidden. n8n records a dedupe key when the item passes Remove Duplicates, before the
commit, so a commit that then fails is not offered again automatically; the error workflow reports it. That errs the
same way as `unknown` (no double commit). And n8n keeps 10,000 keys by default, not a time window, so `window_days`
is not carried over. The export card says both in words.

### 4. Fixtures: held-out instances, read shapes, text fields
- **Capture 8 instances by default** (was 6, [ADR 0027](0027-fixture-capture-and-connector-content.md)); the minimum
  stays 3. The reads cost no model spend.
- **Held-out instances.** Of n captured instances, 2 are held out when n ≥ 6, 1 when n is 4 or 5, none when n ≤ 3.
  - Which ones: those with the lowest `sha256(build_id ‖ instance_ref)`. Each build of the same brief draws a fresh
    split, as [ADR 0029](0029-build-verdicts.md) does for the held-out check.
  - Held-out instances never enter a worker sandbox. The verification sandbox runs the held-out check against them,
    and the worker learns only that it failed.
  - This repeats, on real instances, the bench finding that held-out checks were the real signal
    ([ADR 0012](0012-builder-policy-one-worker-held-out-fan-out.md)).
- **Read shapes.** For each `read` step, code derives a JSON Schema from the captured outputs:
  - keys present in every output are required, keys present in some are optional;
  - types are the observed JSON types, and array items are merged;
  - values are never stored.

  The shape goes into the resolved definition and its hash. At run time, a missing required key or a changed type is
  drift (section 6). Extra keys are not.
- **Text fields.** Fields the brief marks `parse_text` (a mail body, a notes document) are tokenised span by span
  instead of as one value. The masker's rules replace people, emails, phones, URL paths and ids with fixture tokens
  and destroy structured secrets ([ADR 0005](0005-masked-text-only-reaches-models.md)). Numbers, dates, currency codes
  and other words stay, so a transform can be built and replayed against them. This lets masked words reach the
  build sandbox provider, so it waits on [OQ-31](../OPEN_QUESTIONS.md#oq-31-masked-text-fields-in-build-sandboxes)
  and is built in ROADMAP task m5-11, not in m5-10.
  Until then a fix that must parse text says so and relies on checks and the held-out check.

### 5. Running on the native backend
- **Durable state stays ids only.** Read outputs and commit items are written to the run's content rows (C6, as
  m2-10 stores them) and each durable step returns their ids ([ADR 0009](0009-durable-execution-on-postgres.md)).
  The interpreter's `RunResult` is an in-memory value, never a step output.
- **Skipping and dropping.** A step run for one `foreach` element returns `null` to drop it (not counted, for
  example a mail that is not an invoice) or `{ "$skip": "<code>" }` to set it aside, counted, with a code matching
  `^[a-z_]{1,32}$`. Error text is still reduced to the step name.
- **Retries** run inside the durable step, with backoff on the runtime's clock. The semantics are those of DBOS step
  retries (`maxAttempts`, `backoffRate`, an interval). A crash mid-retry re-runs the whole step, which is safe because
  only `read`, `draft` and `model` steps retry. Keeping the loop in the step leaves the `DurableRuntime` port unchanged
  and testable under a fake clock. Retries apply to retryable errors only: timeouts, 429, 5xx, provider overload. Each
  attempt counts against `run_budget_usd`.
- **Commits are never retried automatically.** Item outcomes follow [ADR 0004](0004-every-external-action-is-gated.md).
  A `failed_before_send` item is offered again in the next run's batch; `unknown` is never offered again unless a
  person releases it.
- **`skip_item`** sets one element of a `foreach` aside with an error code (no content) and lets the others continue.
  If more than `max_skipped_items` are skipped, the run fails. **A failed run commits nothing**: the batch is built
  only when every step has finished.
- **Dedupe** runs before the batch is built. An item is dropped when its dedupe hash, `sha256(routine_id ‖ rendered
  key)`, has a journal row in `pending`, `sending`, `sent` or `unknown` in this routine (any version) within
  `window_days`. `pending` matters: a batch still waiting for approval must not be proposed again by the next run.
  Only `failed_before_send` frees a key. Dropped items
  are counted and named in the batch card, for example "2 invoices already billed".
- **Opaque workflow tools ask every time.** A catalog entry or user-added MCP endpoint flagged `opaque_workflow` (a
  tool that fronts another automation, such as an n8n or Activepieces workflow) can change behaviour without its pin
  changing. Its commits always ask and never graduate, like browser commits (policy rule `core.commit.opaque_ask`,
  [ADR 0017](0017-policy-engine-cedar.md)).

### 6. Versions, rollback, drift and the stability record
- **Versions** stay immutable (`routine_versions`). Each row gains `backend` and `rolled_back_from`; the definition
  carries read shapes.
- **Rollback**: `POST /v1/routines/{id}/rollback { to_version, artifact_sha256, receipt_hash, definition_hash }`.
  - It is a deploy approval (kind `deploy`) over the target version's own hashes, shown in words first.
  - The runtime re-lists that version's pins first. If one changed, the rollback is `409 needs_review` and the user
    repairs instead ([ADR 0033](0033-pinned-connector-resolution-and-launch-catalog.md)).
  - It creates a new version number with `rolled_back_from` set and starts in `ask_before_commit` with streak 0.
  - It is audited as `routine.rolled_back`.
- **Repair** stays the way to follow a changed world (new fixtures, new held-out check, OK, build, deploy).
- **Drift** has three sources, all outside Offload:
  - tool pins, checked before each run (existing);
  - read shapes, checked on every read: new breaker reason `read_shape_changed`, routine `needs_review`, nothing
    committed;
  - credential or account change (existing).

  Offload's own side is covered separately: backend conformance is checked in CI on every release.
- **Stability record** per routine version, computed in code from runs and the item journal:
  - runs by outcome;
  - items `sent`, `failed_before_send`, `unknown`, skipped and deduped;
  - reads that needed a retry;
  - p50 and p95 run seconds.

  Each is a Figure with arithmetic and run ids as evidence ([ADR 0003](0003-numbers-come-from-code.md)), shown on
  Routines. When more than 25% of reads needed a retry over the last 20 runs, the routine shows a "needs you" line;
  it does not pause. The existing breakers still pause.

### 7. n8n, Activepieces and other engines
- **Offload's own engine is the default runtime.** n8n is never an execution backend: it holds credentials and makes
  the commit call itself, so it cannot pass conformance rules 1 to 3.
- **Offload does not host or ship n8n.** "Offload builds and runs it inside n8n for you" is **gated**: nothing is
  built until n8n confirms in writing what agreement it needs
  ([OQ-32](../OPEN_QUESTIONS.md#oq-32-written-license-confirmation-from-n8n)). It would make n8n an execution backend
  that fails conformance rules 1 to 3, so it would also need a new ADR.
- **Export to the user's own n8n** (decided, [OQ-30](../OPEN_QUESTIONS.md#oq-30-n8n-in-offload)): section 9. An
  **export target**, not a backend.
- **Connect the user's own n8n workflows as tools**, unchanged: a user may add their own n8n workflows (n8n's MCP
  Server Trigger) or their own Activepieces pieces (Activepieces' MCP server) as an MCP connection. These are rung 1
  and `opaque_workflow`. This matches n8n's "Triggering or executing pre-built workflows via API or webhooks is fine".
  An n8n workflow Offload exported and the user later connects back as a tool is still `opaque_workflow`: Offload
  cannot see whether the user changed it.
- **Activepieces pieces as code** (MIT, outside its `ee` folders) may be ported one at a time into allowlisted
  direct-API adapters run by the broker, with `NOTICE` entries. Third-party piece code never runs inside the broker
  as is. Spike **S8** ports one piece (QuickBooks or Xero) and writes the effort and the license check into this ADR.
- **n8n code is never copied or shipped**: not node source, not the Workflow SDK, not the MCP server (Sustainable Use
  License, [AGENTS.md](../../AGENTS.md#license-boundary-and-notices)). The export writes n8n's documented JSON
  format with Offload's own code. Node type names, `typeVersion`s and parameter keys in the node catalog are
  interface facts taken from n8n's public docs and checked against a live instance, not code.

### 8. What is core and what is `ee/`
Safety and the single-player loop are core ([OPEN_CORE.md](../OPEN_CORE.md#2-feature-split)).

| Part | Where |
|---|---|
| `routine.json` v2, the `ExecutionBackend` port, the native backend, the conformance suite | core |
| Tool choice, scaffold, static validation, held-out instances, read shapes, replay | core |
| Versions, rollback, drift, stability record, `core.commit.opaque_ask` | core |
| Sharing a verified routine definition with other members or workspaces as a starting brief, re-pinned to their connections and re-verified on their fixtures | `ee/packages/teams` (Pro, `teams`) |
| N-of-M deploy and rollback approvals; Cedar policies that restrict backends, adapters or rungs per workspace | `ee/packages/governance` (Enterprise) |
| Deploy, rollback and drift events streamed to a SIEM | `ee/packages/audit-export` (Enterprise) |
| The n8n export, its node catalog, lint and pinned-data test, and push to the user's own n8n (section 9) | core (single-player; [OQ-30](../OPEN_QUESTIONS.md#oq-30-n8n-in-offload)) |
| Restricting or forcing n8n export and push per workspace | `ee/packages/governance` (Enterprise) |
| Any adapter for a third-party engine that needs a vendor agreement, including n8n run by Offload | `ee/`, only with that agreement and a new ADR; gated on [OQ-32](../OPEN_QUESTIONS.md#oq-32-written-license-confirmation-from-n8n) |

### 9. The n8n export
Built in slice [m5-12-n8n-export](../../slices/m5-12-n8n-export/SPEC.md). n8n facts below were checked on
2026-11-22 in n8n's public docs ([research section 3.1](../research/workflow-engines-2026-11.md#31-n8n)).

#### 9.1 What it is
- An **export target**, not an execution backend. `exportN8n(resolved, artifact, receipt, fixtures, catalog)` in
  `packages/n8n-export` (core, MIT) is pure and returns a bundle (the main workflow, its error workflow, a credential
  map, the pinned n8n version and the node bindings used, by `binding_hash`), its `export_hash` and the export card.
  Same inputs, byte-identical bundle.
- `export_hash = sha256(JCS(bundle))`, computed with the main workflow's `settings.errorWorkflow` set to the fixed
  placeholder `offload:error-workflow`. That field is the only value ever filled after approval (section 9.5). The
  card is generated from the bundle by code and is not hashed.
- Made only from a build whose receipt passes WF8, by the member whose build and fixtures they are (section 9.4). The
  routine definition stays the source; the export is derived and never edited by a model.
- A run in the user's n8n is **outside Offload's gate, item journal, broker, approvals, breakers and hours-saved
  measurement**. The export card says so in words before download or push, for example: "This runs in your n8n, not
  in Offload. Offload will not ask before each batch and will not count the time it saves."

#### 9.2 Mapping
**Node bindings.** A step is exported only through a **node binding**: a catalog entry that ties one pinned Offload
tool ([ADR 0033](0033-pinned-connector-resolution-and-launch-catalog.md)) to one n8n node. A binding holds:
- `offload`: the provider, rung and tool name or OpenAPI operation id it stands for;
- `n8n`: `type`, `typeVersion`, credential type;
- `parameters`: a table from the step's `args` keys (and fixed values) to node parameter paths. An arg with no row
  cannot be exported;
- `output_shape` (read nodes) or `input_shape` (commit nodes): a read shape (section 4) recorded from that node on the
  pinned n8n release, run by the operator against a test account. Keys and types only, never values;
- `docs` and `checked` (a docs.n8n.io URL and a date).

`binding_hash = sha256(JCS(binding))`, and the bundle lists the hash of every binding it used.
- A **direct API** step (rung 3) binds to an HTTP Request node that calls the same OpenAPI operation that was pinned
  (method, path, query and body from that operation), with a predefined credential type, which n8n recommends "when
  it's available". The response is that API's own response, so its shape matches by construction; it is still
  checked.
- An **MCP or Composio** step exports only if a binding exists for that exact tool (for example the Gmail node for
  `mail.search`), and only if the shape check passes (section 9.3).

| Routine definition | n8n |
|---|---|
| `schedule` trigger | Schedule Trigger with a five-field cron expression; `settings.timezone` (WF1) |
| `manual`, `webhook` trigger | Manual Trigger, Webhook |
| `read` step | the node of its binding |
| `foreach` | n8n runs a node once per input item; an array field is split by the catalog's split node |
| `transform` step | Code node, JavaScript, "Run Once for All Items". The TypeScript transform module is transpiled to JavaScript with Bun's built-in transpiler (no new dependency), and the `@offload/routine-sdk/pure` helpers it uses are inlined under their MIT header, so the node has no `import` and no TypeScript. A fixed wrapper calls the result per element, drops `null` and marks `$skip` results; a skip check (If node, helper) sends marked items to the skipped-items node. The inlined JavaScript is what the pinned-data test runs |
| `model` step | the catalog's model-call node using the user's own model credential in their n8n, then a Code node that checks the output against the step's output schema (helper node). Text goes from the user's n8n to the user's model provider unmasked, not through Offload's router; the card says so |
| `commit` step | Remove Duplicates (helper node, WF5), then the node of its binding, `retryOnFail: false` |
| `skip_item` on a `read` or `model` step | `onError: "continueErrorOutput"`, error output to the one skipped-items node (No Operation, helper node, WF3). Exported only once the live test shows such a node can still be pinned, since n8n pins only "nodes that have a single main output"; until then `export_unsupported` |
| failed run | the error workflow: Error Trigger, then one notification node (WF3). It must be published with the main workflow: "You have to publish the workflow that uses the Error Trigger node" |

A step with `runs_on: device`, a browser connector, an `opaque_workflow` connection or no binding cannot be exported:
`export_unsupported` with the step id. Nothing partial is exported.

Purity of transforms comes from Offload's isolate check at build time, not from n8n. n8n's Code node "can't access
the file system or make HTTP requests", but self-hosted n8n can be set up to import npm modules; the exported code
imports nothing.

#### 9.3 Validation
- **Schema.** No published JSON Schema for n8n workflow files was found (2026-11-22). Offload keeps a zod schema,
  `N8nWorkflowFile`, of the subset it emits, written from the public API's create-workflow schema: required `name`,
  `nodes`, `connections`, `settings`; node fields such as `type`, `typeVersion`, `parameters`, `credentials`,
  `retryOnFail`, `maxTries`, `waitBetweenTries`, `onError`, `notes`; `additionalProperties: false`. Fields the API
  marks read-only (`id`, `active`, `tags`, `meta` and others) are never emitted.
- **Pinned node catalog.** `packages/n8n-export/catalog/n8n-<version>.json`, pinned to one n8n release named when the
  slice starts. It holds the node bindings (section 9.2) and the helper nodes (`type`, `typeVersion`, the parameter
  keys the export may set, outputs). n8n keeps a node's version inside a saved workflow ("If a user builds and saves
  a workflow using version 1, n8n continues to use version 1 in that workflow"), so a pinned `typeVersion` is what the
  user gets. A node, version or parameter key outside the catalog is `n8n_node_not_pinned`.
- **Shape check.** Each read step's `read_shape`, derived from what Offload's own connector returned, must fit inside
  its binding's `output_shape`: every required key exists there with the same type, recursively. Otherwise the
  export is refused with `export_shape_mismatch`. Each commit step's item fields must fit its binding's
  `input_shape`. Pinned data that does not fit the binding's shape fails the pinned-data test
  (`pinned_shape_mismatch`).
- **Lint.** WF1 to WF8 (section 3.4).
- **Pinned-data test.** Offload's own evaluator runs the bundle: read, trigger and model nodes return their
  `pinData`; Code nodes run the inlined JavaScript in the transform isolate; Remove Duplicates runs (its own
  `pinData` is set aside) and keeps its state across the runs of a case; commit nodes are captured, never called.
  Their inputs must equal the expected items by `item_hash`. This is Offload's reading of n8n's semantics for the
  subset it emits. A `LIVE:` test creates each acceptance case on a real n8n of the pinned release through its API,
  reads it back and deletes it, and skips without one.
- **What is verified, and what is not.** [ADR 0033](0033-pinned-connector-resolution-and-launch-catalog.md) says what
  was verified is what runs. For an export that holds only in part, and the card says so:
  - verified: the step graph, the transforms as shipped (the inlined JavaScript), the model output checks, the
    dedupe keys, and that each n8n node returns and accepts the same keys and types as the tool Offload verified
    against (shape check);
  - not verified: that an n8n node's values match the Offload tool's values for the same item (for example how a mail
    body is decoded), and anything in the user's own n8n, accounts and credentials. Offload never runs the workflow
    in the user's n8n.

  The card asks the member to run one test in their n8n editor with their own data before publishing: unpin the read
  nodes and keep the write nodes pinned, so the test reads live data and writes nothing (section 9.4).

#### 9.4 Download
- `GET /v1/builds/{id}/n8n-export` returns the bundle and the card for a build whose receipt passes WF8, to the member
  whose build it is. A file the member downloads is not an external action.
- **Pinned data on every node that could write.** `pinData` holds the visible instances' outputs for the trigger,
  every read node and every model node, and the expected items for every Remove Duplicates node and every commit node.
  n8n uses pinned data "instead of fetching fresh data" in test runs, so a test run in the editor reaches no app and
  writes nothing to the duplicate history. Pinned data "isn't available for production workflow executions", so
  production runs read and write for real. The card says both.
- **Data class.** `pinData` is derived from C6 connector content ([ADR 0027](0027-fixture-capture-and-connector-content.md)):
  strings are fixture tokens; numbers, dates, currency codes and enum values stay, and after
  [OQ-31](../OPEN_QUESTIONS.md#oq-31-masked-text-fields-in-build-sandboxes) masked words of `parse_text` fields stay
  too. The token map never leaves Offload. In a download or push this C6-derived data leaves Offload's retention
  (`R-content`), member wall and forget path, at the member's own request. So: only the member whose fixtures they
  are can export them (the member wall applies to the export route); an export cannot be made after the fixtures
  expire (`409 fixtures_expired`); Offload keeps no copy of the bundle, only ids and hashes; and the card says, before
  download or push, "This file holds masked samples of your last items: names, emails and ids are replaced; amounts,
  dates and currency codes are kept."
- **Import note.** Map each credential placeholder (the error workflow's notification node too); select the error
  workflow in the main workflow's settings; publish the error workflow whenever you publish the main one. n8n says
  "You can't test error workflows when running workflows manually."

#### 9.5 Push to the user's own n8n (optional)
- **Connect.** The member adds "Your n8n": an https base URL and an API key they create in n8n. The broker refuses a
  host that resolves to a private, loopback, link-local or metadata address unless the egress setting
  `n8n_allow_private_hosts` is on (off by default; an operator who runs Offload and n8n on one private network may turn
  it on). This is configuration, not a branch on where Offload runs
  ([ADR 0037](0037-hosting-cloud-and-self-host-parity.md)). The key is a credential kept by the broker
  ([ADR 0034](0034-credential-broker-and-key-providers.md)) for connection provider `n8n_instance`; the broker sends
  it only to that host, as the `X-N8N-API-KEY` header, and follows no redirect. From n8n 2.14.0 keys can be scoped
  on every plan; the connect screen asks for workflow scopes only.
- **Approve.** A deploy approval ([ADR 0032](0032-deploy-approval-binds-definition.md)) with `target: n8n` binds
  `artifact_sha256`, `receipt_hash`, `definition_hash`, `export_hash`, the connection id and `publish` (true or
  false), shown in words first. The approval's `target` says where it runs; the definition's `backend` (`native`)
  says what it was verified on. The words name the n8n host, say which accounts are used ("the credentials you map in
  your n8n; Offload does not see which account") and, when `publish` is true, that both workflows are published.
- **Send.** The broker re-checks the approval and that the bodies hash to `export_hash` (with the placeholder),
  then:
  1. `POST /api/v1/workflows` for the error workflow;
  2. `POST /api/v1/workflows` for the main workflow, with `settings.errorWorkflow` set to the id n8n returned;
  3. only if `publish`: `POST /api/v1/workflows/{id}/publish` for the error workflow, then for the main workflow
     (n8n marks `/activate` deprecated).

  Each call writes an item journal row first and ends `sent`, `failed_before_send` or `unknown`. Audit
  `n8n.export_pushed`.
- **Retries and idempotency.** Each create carries `Idempotency-Key` = `sha256(push_id ‖ step)`, where `push_id` is
  the `n8n_pushes` row of this approval, so a new push of the same export gets new keys and never a stored response
  of an old one. n8n honours the header "from n8n 2.45.0", "keeps the first successful response for 12 hours", and
  after that "the same key runs the POST again and can create a duplicate"; the publish route lists no such header.
  So: an `unknown` call is never sent again automatically ([ADR 0004](0004-every-external-action-is-gated.md)). The
  member may release it; the resend reuses the same key, and the words warn that on n8n before 2.45.0, or more than 12
  hours after the first send, it can make a second workflow, so check your n8n first.
- **One system at a time.** A push is refused while a routine from the same brief is active on the native backend
  (`409 native_active`). A native deploy of a brief that was pushed is refused with `409 n8n_pushed` unless its
  approval confirms the n8n copy is off, and its words say "This fix was also sent to your n8n. Turn it off there
  first, or both will run." The two systems' dedupe keys cannot see each other.
- **Switch.** Push is behind the setting `n8n_push`, off by default until
  [OQ-32](../OPEN_QUESTIONS.md#oq-32-written-license-confirmation-from-n8n) is answered. That default is a
  recommendation, not the owner's decision; the owner may switch it on.

#### 9.6 License position
Offload runs no n8n and ships no n8n code in either path. The export file is closest to what the FAQ allows a
consultant: "you can charge the client for installing, configuring, building workflows, and maintaining n8n on their
behalf". The push is closer to the words the FAQ uses for what is not allowed ("our API ... an AI agent acting on the
user's behalf"). Both carry a risk for the **user's** own free use, because the FAQ's headline says "If workflows are
only created or modified by you or people in your organization, you can use n8n under the Community license for
free", and these workflows are generated by Offload. All three questions go to n8n in OQ-32; push ships off and the
card tells the member. n8n run by Offload is not built. Details and quotes:
[research section 3.1](../research/workflow-engines-2026-11.md#31-n8n) and
[section 7](../research/workflow-engines-2026-11.md#7-license-risks-stated-plainly).

## Consequences
- **Stability comes from Offload's own code on the engine it already runs.** No new runtime component, nothing new to
  self-host. Parity holds ([ADR 0037](0037-hosting-cloud-and-self-host-parity.md)).
- **"Faster" does not come from a second engine.** It comes from integration sources: MCP (including users' own n8n
  and Activepieces), Composio, and ported MIT pieces. Coverage on day one is what the launch catalog verifies, not
  2,000 nodes. The owner should hear this plainly.
- **The model writes less of each fix.** The graph comes from the brief. Workers write transforms, prompts and
  templates, which the checks, replay and held-out instances test.
- **Contract changes land first, in slice [m5-10-workflow-backend](../../slices/m5-10-workflow-backend/SPEC.md)**,
  which updates [API.md](../API.md) and [DATA_MODEL.md](../DATA_MODEL.md):
  - `routine.json` v2;
  - brief fields `item_identity`, `parse_text`, `tool_choice`;
  - `routine_versions.backend` and `rolled_back_from`;
  - breaker reason `read_shape_changed`;
  - the rollback route;
  - the stability record in `GET /v1/routines/{id}`;
  - the lint of the workflow design rules and `WORKFLOW_DESIGN_RULES`.

  The n8n export's contract changes land in slice [m5-12-n8n-export](../../slices/m5-12-n8n-export/SPEC.md): the
  bundle and `export_hash`, the `n8n_instance` connection, deploy approvals with target `n8n`, `n8n_pushes`, the
  `n8n_push` setting, `GET /v1/builds/{id}/n8n-export` and `POST /v1/builds/{id}/n8n-push`.
- **Earlier decisions change.**
  - [ADR 0027](0027-fixture-capture-and-connector-content.md): the default number of captured instances goes from 6
    to 8, and some are held out.
  - [ADR 0012](0012-builder-policy-one-worker-held-out-fan-out.md) step 1: workers get the visible instances only,
    not every fixture.
  - Span tokenisation of `parse_text` fields replaces whole-value tokens for those fields once OQ-31 is answered.
  - [ADR 0027](0027-fixture-capture-and-connector-content.md): C6-derived values (tokenised) may leave Offload in an n8n
    export, at the member's request, under the rules of section 9.4.
  - [ADR 0032](0032-deploy-approval-binds-definition.md): a deploy approval gains `target` (`native` or `n8n`); an
    `n8n` approval also binds `export_hash`, the connection and `publish`, through a second route,
    `POST /v1/builds/{id}/n8n-push`.
  - [ADR 0033](0033-pinned-connector-resolution-and-launch-catalog.md): for an export, "what was verified is what runs"
    holds only up to the node bindings' shape check (section 9.3).
- **Fewer visible instances per build.** 6 of 8 instead of 6 of 6. When only 3 instances exist, nothing is held out
  and the build says so.
- **A tool behind an MCP endpoint that fronts a workflow cannot graduate.** Users who bring their own n8n keep
  approving each batch.
- **Every new backend must pass the conformance suite**, so a second backend is a lot of work by design.
- **Every routine is built to the eight workflow design rules**, checked by lint, so "well designed" is a test result,
  not a claim. Briefs must name `item_identity` for every commit step (WF5).
- **Users who run n8n get the fix as n8n workflow JSON**, built by Offload, its logic verified on Offload's data and
  its node shapes checked against the pinned n8n release, and run by them. Offload gives up the gate, the journal and
  the measurement for those runs, and does not verify n8n's values or the user's accounts; the card says so
  (section 9.3). Push to their instance is built but
  switched off until n8n answers in writing (OQ-32).
- **The n8n node catalog is upkeep.** Each new n8n release the export targets needs the catalog re-checked against a
  live instance; until then the export keeps the pinned versions.

## Alternatives considered
- **n8n hosted by Offload as the execution backend.** Rejected:
  - its license forbids AI-built, per-user workflows on Offload-run n8n without an OEM agreement;
  - it would bypass the gate and the broker;
  - it adds a server and Redis ([research section 3.1](../research/workflow-engines-2026-11.md#31-n8n)).
- **Deploying fixes into the user's own n8n by API as a backend.** Rejected as a backend: it fails conformance rules
  1 to 3. Kept as an export target with an optional push (section 9), labelled as outside the gate.
- **n8n run by Offload for users now** ("Offload builds and runs it inside n8n for you"). Gated, not rejected: it
  needs n8n's written answer and an agreement (OQ-32), and it would still fail conformance rules 1 to 3.
- **Generating n8n JSON with n8n's own Workflow SDK or MCP server.** Both validate workflows, but using them means
  running or shipping n8n code under the Sustainable Use License inside Offload. Offload writes the JSON itself and
  checks it against its own schema, a pinned catalog and a live import test.
- **Export only, no push.** Simpler and the lowest license risk, but the owner asked for n8n engineering, and a user
  who must import by hand often doesn't. Push is built and switched off by default instead.
- **Activepieces community edition hosted by Offload.** The license allows it (MIT). Rejected: same credential
  problem, plus Redis and workers. Its pieces are used as an integration source instead.
- **Windmill.** AGPL plus proprietary community images; a commercial license is needed to build a paid feature on it.
- **Temporal.** MIT, best replay testing. Rejected again for the reasons in [ADR 0009](0009-durable-execution-on-postgres.md).
  Its replay-in-CI practice is what the conformance suite's golden cases borrow.
- **A separate workflow IR wrapping `routine.json`.** Two formats, two hashes, nothing gained.
- **A graph IR with branches, expressions and error routes** (n8n, OpenFlow style). Harder to validate, to verify and
  to describe in words before the deploy approval. Transforms cover conditions.
- **The worker writes the whole definition** (the v1 practice). The graph would be re-invented per build; replaced by
  the scaffold.
- **Resolve tools at run time.** Already rejected ([ADR 0033](0033-pinned-connector-resolution-and-launch-catalog.md)).

## Sources
- [Workflow engines for Offload fixes](../research/workflow-engines-2026-11.md) (all external facts, checked
  2026-11-22).
- n8n: [LICENSE.md](https://github.com/n8n-io/n8n/blob/master/LICENSE.md),
  [license FAQ](https://docs.n8n.io/n8n-community-license/community-license/license-faq.md),
  [MCP Server Trigger](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-langchain.mcptrigger.md).
- [Activepieces LICENSE](https://github.com/activepieces/activepieces/blob/main/LICENSE).
- [DBOS step retries](https://docs.dbos.dev/typescript/tutorials/step-tutorial) and
  [upgrading workflows](https://docs.dbos.dev/typescript/tutorials/upgrading-workflows.md).
- [Temporal replay testing](https://docs.temporal.io/develop/typescript/testing-suite.md).
- [Windmill step mocking](https://www.windmill.dev/docs/flows/step_mocking) (the idea of pinned step results, which
  replay fixtures already cover).
- n8n docs, checked 2026-11-22: [API](https://docs.n8n.io/api/), [authentication](https://docs.n8n.io/api/authentication/),
  [workflows API](https://docs.n8n.io/connect/n8n-api/build-and-run/workflows.md),
  [export and import](https://docs.n8n.io/build/manage-workflows/export-and-import.md),
  [pin data](https://docs.n8n.io/build/work-with-data/pin-and-mock-data.md),
  [error handling](https://docs.n8n.io/build/flow-logic/handle-errors-gracefully.md),
  [node settings](https://docs.n8n.io/build/understand-workflows/workflow-components/work-with-nodes.md),
  [workflow settings](https://docs.n8n.io/build/manage-workflows/configure-workflow-settings.md),
  [Remove Duplicates](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.removeduplicates.md),
  [Code node](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.code.md),
  [Schedule Trigger](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.scheduletrigger.md),
  [HTTP Request](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.httprequest.md),
  [node versioning](https://docs.n8n.io/connect/create-nodes/build-your-node/reference/versioning.md).
- Owner ask of 2026-11-22 and owner decision of 2026-11-22 ([OQ-30](../OPEN_QUESTIONS.md#oq-30-n8n-in-offload)).
