---
id: m5-12-n8n-export
title: n8n export - import-ready n8n workflow JSON for the user's own n8n from a verified build, checked against a schema, a pinned node catalog and the workflow design rules, with a pinned-data test, and an optional push to the user's own n8n under a deploy approval
milestone: M5
status: ready
depends_on: [m5-10-workflow-backend, m2-02-connections-catalog, m2-03-credential-broker]
parallel_safe: true
human_gated: false
model_tier: sonnet
size: L
parallel_group: M5-D
owns: [packages/n8n-export/**, packages/testkit/src/n8n/**, packages/testkit/fixtures/n8n/**, packages/contracts/src/n8n/**, services/api/src/n8n/**, services/broker/src/n8n/**, packages/db/migrations/0512_n8n_export.sql]
verify: bash slices/m5-12-n8n-export/verify.sh
min_tests: 42
paths_in_scope: [packages/n8n-export/**, packages/testkit/src/n8n/**, packages/testkit/fixtures/n8n/**, packages/contracts/src/n8n/**, packages/contracts/schemas/**, services/api/src/n8n/**, services/api/tests/m5-12-n8n-export/**, services/broker/src/n8n/**, services/broker/tests/m5-12-n8n-export/**, packages/db/migrations/0512_n8n_export.sql, packages/policy/src/rules/**, slices/m5-12-n8n-export/**, docs/API.md, docs/DATA_MODEL.md, docs/ARCHITECTURE.md, docs/SECURITY_PRIVACY.md, package.json, bun.lock]
paths_out_of_scope: [ee/**, apps/**, packages/execution-backend/**, packages/routine-sdk/**, packages/masking/**, packages/db/src/**, packages/contracts/src/index.ts, packages/testkit/src/index.ts, docs/adr/**]
red_tests: [SCHEMA, CATALOG, MAP, LINT, PINNED, CASES, EXPORT, PUSH, BOUNDARY]
---

# m5-12-n8n-export

## Summary
Builds the **n8n export** of [ADR 0039 section 9](../../docs/adr/0039-routine-definition-v2-and-execution-backends.md#9-the-n8n-export),
the owner's decision on [OQ-30](../../docs/OPEN_QUESTIONS.md#oq-30-n8n-in-offload) (2026-11-22, verbatim: "Build
worflow automation as an expert n8n engineer"):
1. `exportN8n` turns a verified build (its resolved routine definition, artifact, receipt and tokenised fixtures)
   into an import-ready n8n bundle: the main workflow, its error workflow, a credential map and a card in words;
2. the bundle is checked against Offload's schema of the n8n workflow file, a pinned node catalog (node types and
   `typeVersion`s) and the eight workflow design rules
   ([ADR 0039 section 3.4](../../docs/adr/0039-routine-definition-v2-and-execution-backends.md#34-workflow-design-rules));
3. `pinData` comes from the tokenised visible instances, and a pinned-data test runs the bundle over each
   acceptance case of [m5-10's ACCEPTANCE.md](../m5-10-workflow-backend/ACCEPTANCE.md);
4. the member downloads the bundle, or, if they connected their own n8n and the `n8n_push` setting is on, approves a
   push whose deploy approval binds `export_hash`; the broker then creates the workflows through n8n's public API.

The export is an **export target, not an execution backend**: a workflow run in the user's n8n is outside Offload's
gate, item journal, broker and hours-saved measurement, and the card says so. Offload's own engine stays the default
runtime. n8n run by Offload is not built
([OQ-32](../../docs/OPEN_QUESTIONS.md#oq-32-written-license-confirmation-from-n8n)).

Implements [ADR 0039](../../docs/adr/0039-routine-definition-v2-and-execution-backends.md) sections 3.4 (n8n
column) and 9, using the deploy binding of [ADR 0032](../../docs/adr/0032-deploy-approval-binds-definition.md), the
broker of [ADR 0034](../../docs/adr/0034-credential-broker-and-key-providers.md) and the item outcomes of
[ADR 0004](../../docs/adr/0004-every-external-action-is-gated.md).

**Do not start before m5-10 is done.** It provides `WORKFLOW_DESIGN_RULES`, `lintRoutine`, the resolved definition,
the acceptance cases with their reference and broken artifacts, and the transform isolate wiring this slice reuses.
Where this SPEC names a file an M2 task creates (approvals, connections, settings, the item journal), use the name it
chose and record it under "Scope changes".

Open questions it builds on, with their defaults:
- [OQ-30](../../docs/OPEN_QUESTIONS.md#oq-30-n8n-in-offload): decided; this slice is part (b) of the decision.
- [OQ-32](../../docs/OPEN_QUESTIONS.md#oq-32-written-license-confirmation-from-n8n): default (b). Push is built and
  tested here but ships with `n8n_push` off; the download ships on.

## Contract
**Package and dependencies.**
- New core package `packages/n8n-export` (`@offload/n8n-export`, `"license": "MIT"`), source in `src/`, tests in
  `tests/m5-12-n8n-export/`.
- No new external dependency. It uses `zod` 4.6.7 and `ajv` 8.20.0 (dev) as pinned in `packages/routine-sdk`,
  `@offload/contracts` (`jcs`, `sha256Hex`), `@offload/execution-backend` (`WORKFLOW_DESIGN_RULES`, the resolved
  definition types, the transform isolate runner) and `@offload/testkit` (dev).
- **No n8n code**: no `n8n`, `n8n-workflow`, `n8n-core`, `@n8n/*` package, no n8n Workflow SDK, no n8n MCP server,
  no file copied from n8n's repository (Sustainable Use License, [AGENTS.md](../../AGENTS.md#license-boundary-and-notices)).
  Everything below is written from n8n's public docs (checked 2026-11-22, see
  [research section 3.1](../../docs/research/workflow-engines-2026-11.md#31-n8n)).

**Bundle** (`packages/contracts/src/n8n/`):
```ts
type N8nBundle = {
  n8n_version: string;                 // the catalog's pinned n8n release
  workflow: N8nWorkflowFile;           // main workflow
  error_workflow: N8nWorkflowFile;     // Error Trigger, then one notification node
  credential_map: { placeholder: string; credential_type: string; for_step_ids: string[]; words: string }[];
};
type N8nExport = { bundle: N8nBundle; export_hash: string; card: string[] };
```
- `export_hash = sha256Hex(JCS(bundle))`, with `workflow.settings.errorWorkflow` equal to the fixed placeholder
  `offload:error-workflow`. The card is not hashed; it is generated from the bundle and the resolved definition by
  code, never by a model.
- `N8nWorkflowFile` is a zod schema of the subset Offload emits, written from the public API's create-workflow
  schema: top-level `name`, `nodes`, `connections`, `settings`, `pinData`; per node `id`, `name`, `type`,
  `typeVersion`, `position`, `parameters`, `credentials`, `notes`, `retryOnFail`, `maxTries`, `waitBetweenTries`,
  `onError`; `additionalProperties: false` at every level. Read-only fields (`id` at the top level, `active`,
  `activeVersionId`, `tags`, `meta`, `versionId`, `createdAt`, `updatedAt`) are never emitted. Settings emitted:
  `executionOrder: "v1"`, `timezone`, `errorWorkflow`, `executionTimeout`, `saveDataErrorExecution: "all"`.
- Node ids are deterministic: a UUID-formatted string from `sha256Hex(definition_hash + "\u0000" + node name)`.
  Positions are a fixed left-to-right layout. The same inputs give byte-identical JCS.

**Pinned node catalog** `packages/n8n-export/catalog/n8n-<version>.json`:
- Pinned to one n8n release, chosen when the slice starts (the latest stable 2.x; n8n 3.0 was early access on
  2026-11-22) and recorded under "Scope changes".
- One entry per node the export may emit: `type`, `typeVersion`, `parameters` (the keys the export may set, with
  types), `credential_types`, `outputs` (main outputs; error output when `onError` is `continueErrorOutput`), `docs`
  (a `https://docs.n8n.io/` URL), `checked` (a date).
- Entries needed for the three acceptance cases: Schedule Trigger, Manual Trigger, Error Trigger, Code, If, No
  Operation, Remove Duplicates, HTTP Request, the split node, Gmail, Google Drive, Google Calendar, Google Sheets, the
  CRM node or HTTP Request for case B, the accounting node or HTTP Request for case A, the model-call node (default
  HTTP Request with a predefined credential type for the user's model provider) and one notification node for the
  error workflow (default Send Email).
- Facts the docs did not give on 2026-11-22 (units and limits of `maxTries` and `waitBetweenTries`, the unit of
  `settings.executionTimeout`, the Code node's input syntax, whether a cron expression has a seconds field) are
  decided from a live instance of the pinned version during the slice and written into the catalog with `checked`.

**Functions** (`packages/n8n-export/src/`, all pure unless stated):
- `exportN8n(resolved, artifact, receipt, fixtures, catalog) → N8nExport | { error: "export_unsupported", step_id } | { error: "heldout_not_passed" }`.
  Mapping exactly as [ADR 0039 section 9.2](../../docs/adr/0039-routine-definition-v2-and-execution-backends.md#92-mapping), and:
  - templates become n8n expressions of the form `={{ $json.<path> }}` only, built from the definition's
    `{{ item.<path> }}` and `{{ steps.<id>.output/<pointer> }}` templates; any other expression is
    `n8n_expression_invalid`;
  - a transform becomes a Code node, JavaScript, "Run Once for All Items". A fixed wrapper calls the transform module
    once per element, drops `null`, and marks `{ "$skip": code }` results; a helper If node ("skip check") sends
    marked items to the one skipped-items node (No Operation). The transform source is inlined as built, with no
    other code;
  - a `read` or `model` step with `on_error: "skip_item"` sets `onError: "continueErrorOutput"` and wires its error
    output to the skipped-items node; every other node sets `onError: "stopWorkflow"`;
  - a model step's output check is a Code node that validates the output against the step's output schema and
    refuses any number field ([ADR 0003](../../docs/adr/0003-numbers-come-from-code.md));
  - `pinData` keyed by node name holds the visible instances' tokenised outputs of the trigger, every read node and
    every model node. Held-out instances never enter the bundle.
- `lintN8nExport(bundle, catalog) → Issue[]`: schema (`n8n_schema_invalid`), catalog (`n8n_node_not_pinned`),
  expressions (`n8n_expression_invalid`) and WF1 to WF8 with the rule ids and codes of `WORKFLOW_DESIGN_RULES`. An
  issue is `{ code, rule?, pointer }` and holds no fixture value. `exportN8n` returns no bundle while any issue
  stands.
- `runPinnedTest(bundle, catalog, runs) → { pass, runs: { items, skipped, deduped }[] }`: Offload's evaluator for
  the subset it emits, following `connections` in `executionOrder` v1. Nodes with `pinData` return it; per run, the
  evaluator replaces the pinned data with that run's instances. Code nodes run in the transform isolate. Remove
  Duplicates keeps its keys across the runs of one call. Commit nodes are captured, never called; their input items
  are compared by `item_hash` in token space.
- `cardWords(bundle, resolved) → string[]`: the definition in words (ADR 0032's renderer) plus fixed lines: runs in
  your n8n, not in Offload; Offload does not ask before each batch, keep the item journal or count hours saved; the
  credentials to map; retries wait a fixed time; duplicates are remembered for the last 10,000 items, not
  `window_days`; model text goes from your n8n to your model provider unmasked (when there is a model step).

**Broker** (`services/broker/src/n8n/`):
- Connection provider `n8n_instance`: `base_url` and an API key. `https` only; on Offload Cloud no private, loopback,
  link-local or metadata address after DNS resolution. The key is stored as a credential ([ADR 0034](../../docs/adr/0034-credential-broker-and-key-providers.md))
  and sent only as `X-N8N-API-KEY` to that host. Redirects are not followed.
- `pushN8n(approval, bundle)`: re-checks the approval and that `sha256Hex(JCS(bundle))` with the placeholder equals
  the approved `export_hash`, then sends, each after an item journal row:
  1. `POST {base_url}/api/v1/workflows` with `error_workflow`;
  2. `POST {base_url}/api/v1/workflows` with `workflow`, `settings.errorWorkflow` set to the id step 1 returned
     (the only field filled after approval);
  3. only if the approval has `publish: true`: `POST {base_url}/api/v1/workflows/{id}/publish`.

  Each call sends an `Idempotency-Key` from `export_hash` and the step number. Outcomes follow
  [ADR 0004](../../docs/adr/0004-every-external-action-is-gated.md); an `unknown` call is never sent again
  automatically. A failure after step 1 leaves the error workflow in place, and the push result names it.

**Policy.** Rule `core.n8n.push_ask` in `packages/policy/src/rules/`: a push always needs its own deploy approval; no
policy allow applies and it never graduates.

**Migration** `packages/db/migrations/0512_n8n_export.sql`:
- the connection provider value `n8n_instance`;
- the deploy approval gains `target text NOT NULL DEFAULT 'native'` (`native` or `n8n`), `export_hash text NULL`,
  `n8n_connection_id uuid NULL`, `n8n_publish boolean NULL`, with a check that `target = 'n8n'` sets all three;
- `n8n_pushes`: `tenant_id`, `build_id`, `connection_id`, `export_hash`, `n8n_version`, `error_workflow_id text
  NULL`, `workflow_id text NULL`, `published boolean`, `created_at`. Ids and hashes only;
- the tenant setting `n8n_push boolean NOT NULL DEFAULT false`, where m2 keeps tenant settings.

RLS as on the tables it extends; `n8n_pushes` is tenant-scoped like `routine_versions`.

**API** (contracts first in `packages/contracts/src/n8n/`, then [API.md](../../docs/API.md), routes in
`services/api/src/n8n/`):
- `GET /v1/builds/{id}/n8n-export` returns `200 { bundle, export_hash, card }`; errors `403 heldout_not_passed`,
  `409 state_conflict` (build not ready), `422 export_unsupported { step_id }`.
- `POST /v1/builds/{id}/n8n-push { connection_id, artifact_sha256, receipt_hash, definition_hash, export_hash, publish }`
  is the deploy approval with target `n8n`; returns `201 { error_workflow_id, workflow_id, published }`; errors
  `403 n8n_push_off`, `403 hash_mismatch`, `409 native_active`, `409 state_conflict`, `502 n8n_rejected { status }`.
- Connecting an `n8n_instance` goes through m2-02's connect flow for API-key connections; it is refused with
  `403 n8n_push_off` while the setting is off.
- Audit actions `n8n.export_downloaded` and `n8n.export_pushed`, ids and hashes only.
- Update [DATA_MODEL.md](../../docs/DATA_MODEL.md), [ARCHITECTURE section 11](../../docs/ARCHITECTURE.md#11-routine-runtime)
  and [SECURITY_PRIVACY.md](../../docs/SECURITY_PRIVACY.md) (a new egress: the member's own n8n host) in the same
  commits.

**Fixtures.** `packages/testkit/src/n8n/` holds a fake n8n server (an in-process HTTP server that records requests
and answers the three routes). `packages/testkit/fixtures/n8n/` holds hand-broken bundles for the LINT tests,
synthetic and tokenised like m5-10's fixtures.

## Acceptance
The three cases of [m5-10's ACCEPTANCE.md](../m5-10-workflow-backend/ACCEPTANCE.md), with the same runs, fake clock,
expected items, skipped and deduped counts:
- each case's **reference artifact** exports to a bundle that passes `N8nWorkflowFile`, the pinned catalog and
  WF1 to WF8 with zero issues, and whose `runPinnedTest` over the case's runs gives exactly the expected items,
  skipped codes and deduped counts;
- each **broken artifact** fails: either `runPinnedTest` gives items that differ from the expected ones, or the
  export is refused (case A broken artifact 3 is refused by static validation with `model_number` before any
  export);
- exporting the same build twice gives the same `export_hash`.

## Red tests (write these first, run them, see them fail)
`status: ready` means the SPEC is complete; it still waits on m5-10.

Folders:
- `packages/n8n-export/tests/m5-12-n8n-export/`;
- `services/api/tests/m5-12-n8n-export/` (routes, real Postgres 17);
- `services/broker/tests/m5-12-n8n-export/` (push against the fake n8n server).

Tests never call a real model, a real n8n or any other real service.

| Tag | Test name | Asserts |
|---|---|---|
| SCHEMA | SCHEMA: every acceptance case export parses with N8nWorkflowFile and holds no read-only field | `id`, `active`, `tags`, `meta` absent |
| SCHEMA | SCHEMA: N8nWorkflowFile refuses an unknown top-level, settings or node field | |
| SCHEMA | SCHEMA: the same build gives a byte-identical bundle and export_hash over 3 calls | JCS bytes equal |
| SCHEMA | SCHEMA: export_hash is taken with the error workflow placeholder and changes when any other byte changes | |
| CATALOG | CATALOG: a node type, typeVersion or parameter key outside the pinned catalog is n8n_node_not_pinned | one per kind |
| CATALOG | CATALOG: every catalog entry has type, typeVersion, parameters, credential types, outputs, a docs.n8n.io URL and a check date | |
| CATALOG | CATALOG: the bundle names the catalog's n8n version | |
| MAP | MAP: a schedule trigger becomes a Schedule Trigger with the cron expression and settings.timezone set to the routine's zone | |
| MAP | MAP: a transform becomes a Code node running once for all items with the transform module inlined and a skip check to the skipped-items node | |
| MAP | MAP: a commit step becomes Remove Duplicates on previous executions with workflow scope and the rendered dedupe key, then the catalog node with retryOnFail false | |
| MAP | MAP: read and model nodes carry retryOnFail, maxTries and waitBetweenTries from the retry policy and HTTP Request nodes carry the timeout in milliseconds | |
| MAP | MAP: a skip_item read or model node uses continueErrorOutput wired to the skipped-items node and every other node uses stopWorkflow | |
| MAP | MAP: a model step becomes the catalog model-call node with a credential placeholder, then an output check that refuses a number field | |
| MAP | MAP: templates become n8n expressions of the form $json path only and any other expression is n8n_expression_invalid | |
| MAP | MAP: a step with runs_on mac, a browser connector, an opaque_workflow connection or no catalog node is export_unsupported and nothing is exported | |
| LINT | LINT: WF1 no trigger node, two trigger nodes, no settings.timezone, or an error workflow without exactly one Error Trigger is trigger_invalid | |
| LINT | LINT: WF2 a node that is neither a step nor a named helper, or two nodes with one name, is step_not_single_purpose | |
| LINT | LINT: WF3 no settings.errorWorkflow, continueRegularOutput, continueOnFail or an unwired error output is error_path_missing | |
| LINT | LINT: WF4 a read node without retryOnFail or an HTTP Request node without a timeout is refused and a commit node with retryOnFail is retry_not_allowed | `retry_missing`, `timeout_missing` |
| LINT | LINT: WF5 a commit node without a Remove Duplicates node directly before it is dedupe_missing | |
| LINT | LINT: WF6 a credentials id, a literal Authorization header or a secret-shaped parameter value is credential_inline | canary secret absent from the issue |
| LINT | LINT: WF7 a read or model node without pinData is pinned_test_missing | |
| LINT | LINT: WF8 an export from a receipt whose held-out check or held-out instances did not pass is heldout_not_passed and returns no bundle | |
| LINT | LINT: every issue uses a rule id and code from WORKFLOW_DESIGN_RULES or the schema, catalog and expression codes, and holds no fixture value | |
| PINNED | PINNED: the pinned-data test returns the commit node inputs and never calls a commit node | commit spy 0 |
| PINNED | PINNED: pinData holds only tokenised values of visible instances, keyed by node name | canary: no held-out instance, no detokenised value |
| PINNED | PINNED: Remove Duplicates keeps its keys across the runs of one case and drops a repeated key | |
| CASES | CASES: case A exports to valid n8n JSON whose pinned-data test gives the expected items over every run and each broken artifact fails | |
| CASES | CASES: case B exports to valid n8n JSON whose pinned-data test gives the expected items over every run and each broken artifact fails | |
| CASES | CASES: case C exports to valid n8n JSON whose pinned-data test gives the expected items over every run and each broken artifact fails | |
| EXPORT | EXPORT: GET n8n-export returns the bundle, export_hash and card for a ready build and 403 heldout_not_passed or 409 state_conflict otherwise | real Postgres; audit `n8n.export_downloaded` |
| EXPORT | EXPORT: the card says the workflow runs outside Offload and lists credentials to map, fixed retry waits, the 10,000-key dedupe history and unmasked model text | no model call |
| EXPORT | EXPORT: the credential map gives a placeholder and an n8n credential type per connection and no connection id, account secret or token | |
| PUSH | PUSH: with n8n_push off, connecting an n8n instance or pushing is 403 n8n_push_off | |
| PUSH | PUSH: an n8n instance with an http URL or a private, loopback, link-local or metadata address is refused on Offload Cloud | after DNS resolution |
| PUSH | PUSH: a push without a deploy approval that binds export_hash, the connection and publish sends nothing | fake n8n gets 0 requests |
| PUSH | PUSH: the broker creates the error workflow, then the main workflow with only settings.errorWorkflow filled, then publishes only when approved | fake n8n request log |
| PUSH | PUSH: a bundle whose hash differs from the approved export_hash is 403 hash_mismatch and nothing is sent | |
| PUSH | PUSH: a journal row is written before each call and a timeout after sending leaves unknown, which is never sent again | |
| PUSH | PUSH: a push while a routine from the same brief is active on the native backend is 409 native_active | |
| PUSH | PUSH: the API key goes only to the connected host as X-N8N-API-KEY and never appears in logs, audit rows, durable state or the bundle | canary key; redirect not followed |
| BOUNDARY | BOUNDARY: packages/n8n-export neither depends on nor imports any n8n package or anything under ee/ | package.json and import graph |

Live tests, outside `red_tests` because they skip without an instance: `LIVE: each acceptance case is created on an
n8n of the pinned version through POST /api/v1/workflows, read back equal and deleted`. They run only against an n8n
instance the operator runs for internal testing, never a member's. The catalog's `checked` dates come from that run.

## Out of scope
- **n8n run by Offload** ("Offload builds and runs it inside n8n for you"). Gated on
  [OQ-32](../../docs/OPEN_QUESTIONS.md#oq-32-written-license-confirmation-from-n8n); needs an agreement and a new ADR.
- **Switching `n8n_push` on by default.** An owner decision after n8n's written answer (OQ-32).
- **Reading back runs, errors or changes from the member's n8n**, and any drift or stability record for exported
  workflows.
- **Importing n8n workflows into Offload.** The member's own n8n workflows still reach Offload only as MCP tools
  ([ADR 0039 section 7](../../docs/adr/0039-routine-definition-v2-and-execution-backends.md#7-n8n-activepieces-and-other-engines)).
- **Exporting steps that run on the Mac, browser steps and `opaque_workflow` connections** (`export_unsupported`).
- **Human approval nodes inside the exported workflow** (for example Slack "Send and Wait for Response"). The card
  says the export does not ask before each batch.
- **Web and Mac screens** for the export card, download and push (M8 web, M5 Mac tasks).
- **Changes to m5-10's packages.** This slice imports `@offload/execution-backend`; if it needs a change there, it
  goes back to m5-10's owner as a "Scope changes" note.

## Verify
`bash slices/m5-12-n8n-export/verify.sh`. It needs `DATABASE_URL` (Postgres 17, a disposable `*_test` database)
for the API tests.
- Typecheck.
- The slice suite has at least `min_tests` tests and every tag is present and passing.
- The full suite passes.
- Every change since `BASE` matches `paths_in_scope` and none matches `paths_out_of_scope`.

`min_tests`, `red_tests` and both path lists are read from this front-matter. `BASE` is required once
`status: in_progress`.

## Scope changes
None.
