# 0039. Fixes as versioned routine definitions on pluggable execution backends

Status: proposed (review pending); the n8n parts wait on [OQ-30](../OPEN_QUESTIONS.md#oq-30-n8n-in-offload), span
tokenisation waits on [OQ-31](../OPEN_QUESTIONS.md#oq-31-masked-text-fields-in-build-sandboxes) · Date: 2026-11-22 ·
Extends [ADR 0026](0026-routine-artifact-contract.md) (`routine.json` v2), [ADR 0027](0027-fixture-capture-and-connector-content.md)
(held-out instances, read shapes) and [ADR 0033](0033-pinned-connector-resolution-and-launch-catalog.md) (tool choice)

## Context
The owner asked, verbatim: "it should give well designed workflows maybe even through like n8n to automate things
... we need stable workflows that are built and it needs to research the best tools to make those but n8n may allow
that to happen faster".

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
    `{{ item.vendor_ref }}:{{ item.invoice_number }}`;
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
| 6 | Static validation | code | issue list; any issue fails the attempt like a check failure | section 3.3 |
| 7 | Verification | fresh sandbox | frozen checks; replay of visible instances; held-out check over the held-out instances | [ADR 0029](0029-build-verdicts.md) |
| 8 | Verifier, receipt | Opus; code signs | `receipt_hash` | [ADR 0012](0012-builder-policy-one-worker-held-out-fan-out.md) |
| 9 | Deploy approval | user | binds `artifact_sha256`, `receipt_hash`, `definition_hash` (with `backend`, retry policies, dedupe keys and read shapes inside) | [ADR 0032](0032-deploy-approval-binds-definition.md) |
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
- `backend_not_allowed`.

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
- **Offload does not host or ship n8n**, and n8n is not an execution backend.
- **Now, no license question**: a user may add their own n8n workflows (n8n's MCP Server Trigger) or their own
  Activepieces pieces (Activepieces' MCP server) as an MCP connection. These are rung 1 and `opaque_workflow`, and
  Offload never writes the workflow behind them. This matches n8n's "Triggering or executing pre-built workflows via
  API or webhooks is fine".
- **Later, only if the owner chooses and n8n confirms in writing**: export a verified routine definition as n8n
  workflow JSON for the user's own instance, as a hand-off outside Offload's gate
  ([OQ-30](../OPEN_QUESTIONS.md#oq-30-n8n-in-offload)). Not built and not specced.
- **Activepieces pieces as code** (MIT, outside its `ee` folders) may be ported one at a time into allowlisted
  direct-API adapters run by the broker, with `NOTICE` entries. Third-party piece code never runs inside the broker
  as is. Spike **S8** ports one piece (QuickBooks or Xero) and writes the effort and the license check into this ADR.
- **n8n node source is never copied** (Sustainable Use License, [AGENTS.md](../../AGENTS.md#license-boundary-and-notices)).

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
| Any adapter for a third-party engine that needs a vendor agreement | `ee/`, only with that agreement; none planned |

## Consequences
- **Stability comes from Offload's own code on the engine it already runs.** No new runtime component, nothing new to
  self-host. Parity holds ([ADR 0037](0037-hosting-cloud-and-self-host-parity.md)).
- **"Faster" does not come from a second engine.** It comes from integration sources: MCP (including users' own n8n
  and Activepieces), Composio, and ported MIT pieces. Coverage on day one is what the launch catalog verifies, not
  2,000 nodes. The owner should hear this plainly.
- **The model writes less of each fix.** The graph comes from the brief. Workers write transforms, prompts and
  templates, which the checks, replay and held-out instances test.
- **Contract changes land first, in slice `m5-10-workflow-backend`**,
  which updates [API.md](../API.md) and [DATA_MODEL.md](../DATA_MODEL.md):
  - `routine.json` v2;
  - brief fields `item_identity`, `parse_text`, `tool_choice`;
  - `routine_versions.backend` and `rolled_back_from`;
  - breaker reason `read_shape_changed`;
  - the rollback route;
  - the stability record in `GET /v1/routines/{id}`.
- **Three earlier decisions change.**
  - [ADR 0027](0027-fixture-capture-and-connector-content.md): the default number of captured instances goes from 6
    to 8, and some are held out.
  - [ADR 0012](0012-builder-policy-one-worker-held-out-fan-out.md) step 1: workers get the visible instances only,
    not every fixture.
  - Span tokenisation of `parse_text` fields replaces whole-value tokens for those fields once OQ-31 is answered.
- **Fewer visible instances per build.** 6 of 8 instead of 6 of 6. When only 3 instances exist, nothing is held out
  and the build says so.
- **A tool behind an MCP endpoint that fronts a workflow cannot graduate.** Users who bring their own n8n keep
  approving each batch.
- **Every new backend must pass the conformance suite**, so a second backend is a lot of work by design.

## Alternatives considered
- **n8n hosted by Offload as the execution backend.** Rejected:
  - its license forbids AI-built, per-user workflows on Offload-run n8n without an OEM agreement;
  - it would bypass the gate and the broker;
  - it adds a server and Redis ([research section 3.1](../research/workflow-engines-2026-11.md#31-n8n)).
- **Deploying fixes into the user's own n8n by API as a backend.** Rejected as a backend: it fails conformance rules
  1 to 3 and its license position is unconfirmed. Kept only as a possible export (OQ-30).
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
- Owner ask of 2026-11-22.
