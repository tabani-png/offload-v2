---
id: m5-12-n8n-export
title: n8n export - import-ready n8n workflow JSON for the member's own n8n from a verified build, through node bindings checked against a schema, a pinned node catalog, read shapes and the workflow design rules, with a pinned-data test, and an optional push to the member's own n8n under a deploy approval
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
min_tests: 49
paths_in_scope: [packages/n8n-export/**, packages/testkit/src/n8n/**, packages/testkit/fixtures/n8n/**, packages/contracts/src/n8n/**, packages/contracts/schemas/**, services/api/src/n8n/**, services/api/src/app.ts, services/api/src/connections/**, services/api/src/builds/**, services/api/package.json, services/api/tests/m5-12-n8n-export/**, services/broker/src/n8n/**, services/broker/package.json, services/broker/tests/m5-12-n8n-export/**, packages/db/migrations/0512_n8n_export.sql, packages/policy/src/rules/**, slices/m5-12-n8n-export/**, docs/API.md, docs/DATA_MODEL.md, docs/ARCHITECTURE.md, docs/SECURITY_PRIVACY.md, package.json, bun.lock]
paths_out_of_scope: [ee/**, apps/**, packages/execution-backend/**, packages/routine-sdk/**, packages/masking/**, packages/db/src/**, packages/contracts/src/index.ts, packages/testkit/src/index.ts, docs/adr/**]
red_tests: [SCHEMA, CATALOG, MAP, LINT, PINNED, CASES, EXPORT, PUSH, DEPLOY, BOUNDARY]
---

# m5-12-n8n-export

## Summary
Builds the **n8n export** of [ADR 0040 section 9](../../docs/adr/0040-routine-definition-v2-and-execution-backends.md#9-the-n8n-export),
the owner's decision on [OQ-30](../../docs/OPEN_QUESTIONS.md#oq-30-n8n-in-offload) (2026-11-22, verbatim: "Build
worflow automation as an expert n8n engineer"):
1. `exportN8n` turns a verified build (its resolved routine definition, artifact, receipt and tokenised fixtures)
   into an import-ready n8n bundle: the main workflow, its error workflow, a credential map and a card in words;
2. every step goes through a **node binding** of a pinned node catalog: the binding maps the step's `args` to node
   parameters and carries the node's input or output shape, recorded from the pinned n8n release. A step whose read
   shape does not fit is refused;
3. the bundle is checked against Offload's schema of the n8n workflow file, the catalog and the eight workflow design
   rules ([ADR 0040 section 3.4](../../docs/adr/0040-routine-definition-v2-and-execution-backends.md#34-workflow-design-rules));
4. `pinData` comes from the tokenised visible instances and the expected items, on every node that reads or writes,
   so a test run in the n8n editor writes nothing; a pinned-data test runs the bundle over each acceptance case of
   [m5-10's ACCEPTANCE.md](../m5-10-workflow-backend/ACCEPTANCE.md);
5. the member downloads the bundle, or, if they connected their own n8n and the `n8n_push` setting is on, approves a
   push whose deploy approval binds `export_hash`; the broker then creates and, if approved, publishes both workflows
   through n8n's public API.

The export is an **export target, not an execution backend**: a workflow run in the member's n8n is outside
Offload's gate, item journal, broker and hours-saved measurement, and the card says so, together with what was and
was not verified ([ADR 0040 section 9.3](../../docs/adr/0040-routine-definition-v2-and-execution-backends.md#93-validation)).
Offload's own engine stays the default runtime. n8n run by Offload is not built
([OQ-32](../../docs/OPEN_QUESTIONS.md#oq-32-written-license-confirmation-from-n8n)).

Implements [ADR 0040](../../docs/adr/0040-routine-definition-v2-and-execution-backends.md) sections 3.4 (n8n
column) and 9, using the deploy binding of [ADR 0032](../../docs/adr/0032-deploy-approval-binds-definition.md), the
broker of [ADR 0034](../../docs/adr/0034-credential-broker-and-key-providers.md), the item outcomes of
[ADR 0004](../../docs/adr/0004-every-external-action-is-gated.md) and the C6 rules of
[ADR 0027](../../docs/adr/0027-fixture-capture-and-connector-content.md).

**Do not start before m5-10 is done.** It provides `WORKFLOW_DESIGN_RULES`, `lintRoutine`, the resolved definition,
read shapes, the acceptance cases with their reference and broken artifacts, and the transform isolate this slice
reuses. Where this SPEC names a file an M2 task creates (approvals, connections, settings, the item journal, the
broker's request router), use the name it chose and record it under "Scope changes". `paths_in_scope` includes the
API's route mounting (`services/api/src/app.ts`), m2-02's connect flow (`services/api/src/connections/**`), the deploy
route m5-10 extends (`services/api/src/builds/**`, for the `n8n_pushed` check only) and both services'
`package.json`.

Open questions it builds on, with their defaults:
- [OQ-30](../../docs/OPEN_QUESTIONS.md#oq-30-n8n-in-offload): decided; this slice is part (b) of the decision.
- [OQ-32](../../docs/OPEN_QUESTIONS.md#oq-32-written-license-confirmation-from-n8n): default (b). Push is built and
  tested here but ships with `n8n_push` off; the download ships on. This default is a recommendation the owner may
  overrule.

## Contract
**Package and dependencies.**
- New core package `packages/n8n-export` (`@offload/n8n-export`, `"license": "MIT"`), source in `src/`, tests in
  `tests/m5-12-n8n-export/`.
- No new external dependency. It uses `zod` 4.6.7 and `ajv` 8.20.0 (dev) as pinned in `packages/routine-sdk`,
  `@offload/contracts` (`jcs`, `sha256Hex`), `@offload/execution-backend` (`WORKFLOW_DESIGN_RULES`, the resolved
  definition types, `checkReadShape`, the transform isolate runner), Bun's built-in transpiler (`Bun.Transpiler`) and
  `@offload/testkit` (dev).
- **No n8n code**: no `n8n`, `n8n-workflow`, `n8n-core`, `@n8n/*` package, no n8n Workflow SDK, no n8n MCP server,
  no file copied from n8n's repository (Sustainable Use License, [AGENTS.md](../../AGENTS.md#license-boundary-and-notices)).
  Everything below is written from n8n's public docs (checked 2026-11-22, see
  [research section 3.1](../../docs/research/workflow-engines-2026-11.md#31-n8n)).

**Bundle** (`packages/contracts/src/n8n/`):
```ts
type N8nBundle = {
  n8n_version: string;                 // the catalog's pinned n8n release
  bindings: string[];                  // binding_hash of every node binding used, sorted
  workflow: N8nWorkflowFile;           // main workflow
  error_workflow: N8nWorkflowFile;     // Error Trigger, then one notification node
  credential_map: {
    placeholder: string;
    credential_type: string;
    for_nodes: { workflow: "main" | "error"; node: string }[];  // includes the error workflow's notification node
    words: string;
  }[];
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
- **Node bindings**, one per pinned Offload tool that can be exported
  ([ADR 0040 section 9.2](../../docs/adr/0040-routine-definition-v2-and-execution-backends.md#92-mapping)):
  - `offload`: `{ provider, rung, tool }` (the MCP or Composio tool name, or the OpenAPI operation id);
  - `n8n`: `{ type, typeVersion, credential_type }`;
  - `parameters`: rows `{ arg, parameter_path }` and fixed rows `{ parameter_path, value }`;
  - `output_shape` (read) or `input_shape` (commit): a read shape (JSON Schema subset of m5-10) recorded by running
    the node on the pinned release against an operator test account; keys and types only;
  - `pinnable_with_error_output: boolean` (default false until the live test shows a node with an error output can be
    pinned);
  - `docs` (a `https://docs.n8n.io/` URL) and `checked` (a date).

  `binding_hash = sha256Hex(JCS(binding))`. A direct API (rung 3) tool binds to HTTP Request on the same OpenAPI
  operation, its parameters generated from that operation.
- **Helper and trigger nodes**: `type`, `typeVersion`, the parameter keys the export may set, outputs, `docs`,
  `checked`. Needed for the three cases: Schedule Trigger, Manual Trigger, Error Trigger, Code, If, No Operation,
  Remove Duplicates, the split node, the model-call node (default HTTP Request with a predefined credential type for
  the member's model provider) and one notification node for the error workflow (default Send Email).
- Bindings needed for the three cases: `mail.search`, `mail.read`, `accounting.bill` (case A), `file.read`,
  `crm.note`, `crm.task` (case B), `calendar.events`, `sheet.append` (case C), each for the tool the case's tool
  choice pins.
- Facts the docs did not give on 2026-11-22 (units and limits of `maxTries` and `waitBetweenTries`, the unit of
  `settings.executionTimeout`, the Code node's input syntax) are decided from a live instance of the pinned release
  during the slice and written into the catalog with `checked`. Cron expressions are emitted with five fields.

**Functions** (`packages/n8n-export/src/`, all pure unless stated):
- `exportN8n(resolved, artifact, receipt, fixtures, catalog) → N8nExport | { error: "export_unsupported" | "export_shape_mismatch", step_id } | { error: "heldout_not_passed" }`.
  Mapping as [ADR 0040 section 9.2](../../docs/adr/0040-routine-definition-v2-and-execution-backends.md#92-mapping), and:
  - a step's `args` become node parameters only through its binding's rows; an arg with no row, a step with no
    binding, `runs_on: device`, a browser connector or an `opaque_workflow` connection is `export_unsupported`;
  - each read step's `read_shape` must fit its binding's `output_shape` (`checkReadShape` with the binding's shape:
    every required key present with the same type, recursively), and each commit step's item fields must fit its
    binding's `input_shape`; otherwise `export_shape_mismatch` with the step id;
  - templates become n8n expressions of the form `={{ $json.<path> }}` only, built from the definition's
    `{{ item.<path> }}` and `{{ steps.<id>.output/<pointer> }}` templates; any other expression is
    `n8n_expression_invalid`;
  - a transform becomes a Code node, JavaScript, "Run Once for All Items". `Bun.Transpiler` turns the TypeScript
    module into JavaScript; the `@offload/routine-sdk/pure` helpers it imports are inlined, each under a header naming
    the package and its MIT license; the result has no `import`, no `require` and no TypeScript syntax. A fixed
    wrapper calls it per element, drops `null`, and marks `{ "$skip": code }` results; a helper If node ("skip
    check") sends marked items to the one skipped-items node (No Operation);
  - a `read` or `model` step with `on_error: "skip_item"` sets `onError: "continueErrorOutput"` wired to the
    skipped-items node only when its catalog entry has `pinnable_with_error_output: true`; otherwise
    `export_unsupported`. Every other node sets `onError: "stopWorkflow"`;
  - a model step's output check is a Code node that validates the output against the step's output schema and
    refuses any number field ([ADR 0003](../../docs/adr/0003-numbers-come-from-code.md));
  - `pinData`, keyed by node name: the visible instances' tokenised outputs for the trigger, every read node and every
    model node; the expected items for every Remove Duplicates node and every commit node. Held-out instances never
    enter the bundle.
- `lintN8nExport(bundle, catalog) → Issue[]`: schema (`n8n_schema_invalid`), catalog (`n8n_node_not_pinned`),
  expressions (`n8n_expression_invalid`) and WF1 to WF8 with the rule ids and codes of `WORKFLOW_DESIGN_RULES`
  (WF7 here also requires `pinData` on every Remove Duplicates and commit node). An issue is `{ code, rule?, pointer }`
  and holds no fixture value. `exportN8n` returns no bundle while any issue stands.
- `runPinnedTest(bundle, catalog, runs) → { pass, runs: { items, skipped, deduped }[] }`: Offload's evaluator for
  the subset it emits, following `connections` in `executionOrder` v1. Trigger, read and model nodes return their
  `pinData`; per run, the evaluator replaces it with that run's instances, and any pinned data that does not fit the
  node's binding shape fails with `pinned_shape_mismatch`. Code nodes run the inlined JavaScript in the transform
  isolate. Remove Duplicates runs, with its own `pinData` set aside, and keeps its keys across the runs of one call.
  Commit nodes are captured, never called, with their `pinData` set aside; their input items are compared by
  `item_hash` in token space.
- `cardWords(bundle, resolved) → string[]`: the definition in words (ADR 0032's renderer) plus fixed lines:
  - runs in your n8n, not in Offload; Offload does not ask before each batch, keep the item journal or count hours
    saved;
  - what was verified (the logic on Offload's data, node shapes on n8n `<version>`) and what was not (n8n's values
    for your items, your accounts); run one test in your n8n editor with your own data before you publish: unpin the
    read nodes and keep the write nodes pinned, so the test reads live data and writes nothing;
  - test runs in the editor use pinned data and write nothing; published runs read and write for real;
  - the credentials to map, including the error workflow's; accounts are whatever you map, Offload does not see them;
  - publish the error workflow with the main one; n8n cannot test error workflows in manual runs;
  - retries wait a fixed time; duplicates are remembered for the last 10,000 items, not `window_days`;
  - model text goes from your n8n to your model provider unmasked (when there is a model step);
  - the file holds masked samples of your last items (names, emails and ids replaced; amounts, dates and currency
    codes kept);
  - n8n's license FAQ grants free use when workflows are "only created or modified by you or people in your
    organization"; these were generated by Offload, and n8n has not yet confirmed how that applies
    ([OQ-32](../../docs/OPEN_QUESTIONS.md#oq-32-written-license-confirmation-from-n8n)).

**Broker** (`services/broker/src/n8n/`):
- Connection provider `n8n_instance`: `base_url` and an API key. `https` only. A host that resolves to a private,
  loopback, link-local or metadata address is refused unless the egress setting `n8n_allow_private_hosts` is on
  (configuration, default off; [ADR 0037](../../docs/adr/0037-hosting-cloud-and-self-host-parity.md) rule 1: no branch
  on where Offload runs). The key is stored as a credential
  ([ADR 0034](../../docs/adr/0034-credential-broker-and-key-providers.md)) and sent only as `X-N8N-API-KEY` to that
  host. Redirects are not followed.
- `pushN8n(approval, push_id, bundle)`: re-checks the approval and that `sha256Hex(JCS(bundle))` with the placeholder
  equals the approved `export_hash`, then sends, each after an item journal row:
  1. `POST {base_url}/api/v1/workflows` with `error_workflow`;
  2. `POST {base_url}/api/v1/workflows` with `workflow`, `settings.errorWorkflow` set to the id step 1 returned
     (the only field filled after approval);
  3. only if the approval has `publish: true`: `POST {base_url}/api/v1/workflows/{id}/publish` for the error
     workflow, then for the main workflow.

  Each create sends `Idempotency-Key: sha256Hex(push_id + "\u0000" + step)`. n8n honours it from 2.45.0 and keeps
  the first response for 12 hours; publish lists no such header. Outcomes follow
  [ADR 0004](../../docs/adr/0004-every-external-action-is-gated.md): an `unknown` call is never sent again
  automatically; a member may release it, and the resend reuses the same `push_id` and key. A failure after step 1
  leaves the error workflow in place, and the push result names it.

**Policy.** Rule `core.n8n.push_ask` in `packages/policy/src/rules/`: a push always needs its own deploy approval; no
policy allow applies and it never graduates.

**Migration** `packages/db/migrations/0512_n8n_export.sql`:
- the connection provider value `n8n_instance`;
- the deploy approval gains `target text NOT NULL DEFAULT 'native'` (`native` or `n8n`), `export_hash text NULL`,
  `n8n_connection_id uuid NULL`, `n8n_publish boolean NULL`, `confirm_n8n_off boolean NULL`, with a check that
  `target = 'n8n'` sets the first three;
- `n8n_pushes`: `id` (the `push_id`), `tenant_id`, `member_id`, `build_id`, `brief_hash`, `connection_id`,
  `export_hash`, `n8n_version`, `error_workflow_id text NULL`, `workflow_id text NULL`, `published boolean`,
  `created_at`. Ids and hashes only;
- the tenant setting `n8n_push boolean NOT NULL DEFAULT false`, where m2 keeps tenant settings.

RLS as on the tables it extends; `n8n_pushes` is tenant-scoped and under the member wall
([ADR 0013](../../docs/adr/0013-tenancy-and-rls.md)).

**API** (contracts first in `packages/contracts/src/n8n/`, then [API.md](../../docs/API.md), routes in
`services/api/src/n8n/`, mounted in `services/api/src/app.ts`):
- `GET /v1/builds/{id}/n8n-export` returns `200 { bundle, export_hash, card }` to the member whose build and fixtures
  they are; errors `404` for any other member (member wall), `403 heldout_not_passed`, `409 state_conflict` (build
  not ready), `409 fixtures_expired` (past `R-content`), `422 export_unsupported { step_id }`,
  `422 export_shape_mismatch { step_id }`. Offload keeps no copy of the bundle.
- `POST /v1/builds/{id}/n8n-push { connection_id, artifact_sha256, receipt_hash, definition_hash, export_hash, publish }`
  is the deploy approval with `target: n8n`; returns `201 { push_id, error_workflow_id, workflow_id, published }`;
  errors `403 n8n_push_off`, `403 hash_mismatch`, `409 native_active`, `409 state_conflict`,
  `409 fixtures_expired`, `502 n8n_rejected { status }`.
- The native deploy route (`POST /v1/builds/{id}/deploy`, m5-10) refuses a brief with an `n8n_pushes` row with
  `409 n8n_pushed` unless the approval carries `confirm_n8n_off: true`; its words say "This fix was also sent to your
  n8n. Turn it off there first, or both will run."
- Connecting an `n8n_instance` goes through m2-02's connect flow for API-key connections; it is refused with
  `403 n8n_push_off` while the setting is off.
- Audit actions `n8n.export_downloaded` and `n8n.export_pushed`, ids and hashes only.
- Update [DATA_MODEL.md](../../docs/DATA_MODEL.md), [ARCHITECTURE section 11](../../docs/ARCHITECTURE.md#11-routine-runtime)
  and [SECURITY_PRIVACY.md](../../docs/SECURITY_PRIVACY.md) in the same commits: a new egress (the member's own n8n
  host) and C6-derived `pinData` leaving Offload in an export, at the member's request
  ([ADR 0040 section 9.4](../../docs/adr/0040-routine-definition-v2-and-execution-backends.md#94-download)).

**Fixtures.** `packages/testkit/src/n8n/` holds a fake n8n server (an in-process HTTP server that records requests
and answers the create and publish routes). `packages/testkit/fixtures/n8n/` holds hand-broken bundles for the LINT
tests and synthetic binding shapes for the three cases, synthetic and tokenised like m5-10's fixtures.

## Acceptance
The three cases of [m5-10's ACCEPTANCE.md](../m5-10-workflow-backend/ACCEPTANCE.md), with the same runs, fake clock,
expected items, skipped and deduped counts:
- each case's **reference artifact** exports, through bindings whose shapes fit, to a bundle that passes
  `N8nWorkflowFile`, the pinned catalog and WF1 to WF8 with zero issues, and whose `runPinnedTest` over the case's
  runs gives exactly the expected items, skipped codes and deduped counts;
- each **broken artifact** fails: either `runPinnedTest` gives items that differ from the expected ones, or the
  export is refused (case A broken artifact 3 is refused by static validation with `model_number` before any
  export);
- exporting the same build twice gives the same `export_hash`.

The acceptance shows the export keeps the verified logic. It does not show that n8n's nodes return the same values
as Offload's tools; the card says so.

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
| SCHEMA | SCHEMA: export_hash is taken with the error workflow placeholder and changes when any other byte changes | including a binding hash |
| CATALOG | CATALOG: a node type, typeVersion or parameter key outside the pinned catalog is n8n_node_not_pinned | one per kind |
| CATALOG | CATALOG: every binding has its Offload tool, n8n type and typeVersion, an args-to-parameters table, an output or input shape, a docs.n8n.io URL and a check date | |
| CATALOG | CATALOG: the bundle names the catalog's n8n version and the hash of every binding it used | |
| MAP | MAP: a schedule trigger becomes a Schedule Trigger with a five-field cron expression and settings.timezone set to the routine's zone | |
| MAP | MAP: a step's args become node parameters only through its binding's rows and an arg with no row is export_unsupported | |
| MAP | MAP: a read step whose read shape does not fit its binding's output shape is export_shape_mismatch | missing key and changed type |
| MAP | MAP: a direct API step binds to HTTP Request on the same OpenAPI operation that was pinned | method, path, query, body |
| MAP | MAP: a transform becomes a Code node running once for all items with a skip check to the skipped-items node | |
| MAP | MAP: an inlined transform is plain JavaScript with no import, no require and no TypeScript syntax, and inlined pure helpers carry their MIT header | parses as JavaScript |
| MAP | MAP: a commit step becomes Remove Duplicates on previous executions with workflow scope and the rendered dedupe key, then the binding's node with retryOnFail false | |
| MAP | MAP: read and model nodes carry retryOnFail, maxTries and waitBetweenTries from the retry policy and HTTP Request nodes carry the timeout in milliseconds | |
| MAP | MAP: a skip_item read or model node uses continueErrorOutput only when its catalog entry is pinnable with an error output and is export_unsupported otherwise, and every other node uses stopWorkflow | |
| MAP | MAP: a model step becomes the catalog model-call node with a credential placeholder, then an output check that refuses a number field | |
| MAP | MAP: a step with runs_on device, a browser connector, an opaque_workflow connection or no binding is export_unsupported and nothing is exported | |
| LINT | LINT: WF1 no trigger node, two trigger nodes, no settings.timezone, or an error workflow without exactly one Error Trigger is trigger_invalid | |
| LINT | LINT: WF2 a node that is neither a step nor a named helper, or two nodes with one name, is step_not_single_purpose | |
| LINT | LINT: WF3 no settings.errorWorkflow, continueRegularOutput, continueOnFail or an unwired error output is error_path_missing | |
| LINT | LINT: WF4 a read node without retryOnFail or an HTTP Request node without a timeout is refused and a commit node with retryOnFail is retry_not_allowed | `retry_missing`, `timeout_missing` |
| LINT | LINT: WF5 a commit node without a Remove Duplicates node directly before it is dedupe_missing | |
| LINT | LINT: WF6 a credentials id, a literal Authorization header or a secret-shaped parameter value is credential_inline | canary secret absent from the issue |
| LINT | LINT: WF7 a trigger, read, model, Remove Duplicates or commit node without pinData is pinned_test_missing | |
| LINT | LINT: WF8 an export from a receipt whose held-out check or held-out instances did not pass is heldout_not_passed and returns no bundle | |
| LINT | LINT: every issue uses a rule id and code from WORKFLOW_DESIGN_RULES or the schema, catalog and expression codes, and holds no fixture value | |
| PINNED | PINNED: the pinned-data test returns the commit node inputs and never calls a commit node | commit spy 0 |
| PINNED | PINNED: pinData holds only tokenised values of visible instances and expected items, keyed by node name | canary: no held-out instance, no detokenised value |
| PINNED | PINNED: Remove Duplicates runs with its pinData set aside, keeps its keys across the runs of one case and drops a repeated key | |
| PINNED | PINNED: pinned data that does not fit its binding's shape fails with pinned_shape_mismatch | |
| CASES | CASES: case A exports to valid n8n JSON whose pinned-data test gives the expected items over every run and each broken artifact fails | |
| CASES | CASES: case B exports to valid n8n JSON whose pinned-data test gives the expected items over every run and each broken artifact fails | |
| CASES | CASES: case C exports to valid n8n JSON whose pinned-data test gives the expected items over every run and each broken artifact fails | |
| EXPORT | EXPORT: GET n8n-export returns the bundle, export_hash and card for a ready build and 403 heldout_not_passed or 409 state_conflict otherwise | real Postgres; audit `n8n.export_downloaded` |
| EXPORT | EXPORT: another member of the tenant gets 404 and an export after the fixtures expired is 409 fixtures_expired | member wall; fake clock |
| EXPORT | EXPORT: the card says the workflow runs outside Offload and names what was not verified, the pinned write nodes, the error workflow to publish, the credentials to map, the masked samples and the license question | no model call |
| EXPORT | EXPORT: the credential map gives a placeholder and an n8n credential type per node, the error workflow's notification node included, and no connection id, account secret or token | |
| PUSH | PUSH: with n8n_push off, connecting an n8n instance or pushing is 403 n8n_push_off | |
| PUSH | PUSH: an n8n instance with an http URL is refused, and a private, loopback, link-local or metadata address is refused unless n8n_allow_private_hosts is on | after DNS resolution |
| PUSH | PUSH: a push without a deploy approval that binds export_hash, the connection and publish sends nothing | fake n8n gets 0 requests |
| PUSH | PUSH: the broker creates the error workflow, then the main workflow with only settings.errorWorkflow filled, then publishes the error workflow and the main workflow only when approved | fake n8n request log |
| PUSH | PUSH: a bundle whose hash differs from the approved export_hash is 403 hash_mismatch and nothing is sent | |
| PUSH | PUSH: each create carries an Idempotency-Key from the push id and step so two pushes of one export never share a key | |
| PUSH | PUSH: a journal row is written before each call and a timeout after sending leaves unknown, which is never sent again automatically and reuses its key when a member releases it | |
| PUSH | PUSH: a push while a routine from the same brief is active on the native backend is 409 native_active | |
| PUSH | PUSH: the API key goes only to the connected host as X-N8N-API-KEY and never appears in logs, audit rows, durable state or the bundle | canary key; redirect not followed |
| DEPLOY | DEPLOY: a native deploy of a brief that was pushed to n8n is 409 n8n_pushed unless its approval confirms the n8n copy is off, and its words say so | real Postgres |
| BOUNDARY | BOUNDARY: packages/n8n-export neither depends on nor imports any n8n package or anything under ee/ | package.json and import graph |

Live tests, outside `red_tests` because they skip without an instance: `LIVE: each acceptance case is created on an
n8n of the pinned release through POST /api/v1/workflows, read back equal and deleted`, and
`LIVE: each binding's node returns data that fits its recorded output shape on the operator's test account`. They run
only against an n8n instance and test accounts the operator runs for internal testing, never a member's. The
catalog's shapes and `checked` dates come from these runs.

## Out of scope
- **n8n run by Offload** ("Offload builds and runs it inside n8n for you"). Gated on
  [OQ-32](../../docs/OPEN_QUESTIONS.md#oq-32-written-license-confirmation-from-n8n); needs an agreement and a new ADR.
- **Switching `n8n_push` on by default.** An owner decision after n8n's written answer (OQ-32).
- **Running the export in the member's n8n, or reading back its runs, errors or changes**, and any drift or stability
  record for exported workflows.
- **Mapping nodes** that would reshape an n8n node's output to fit a read shape. A mismatch refuses the export.
- **Importing n8n workflows into Offload.** The member's own n8n workflows still reach Offload only as MCP tools
  ([ADR 0040 section 7](../../docs/adr/0040-routine-definition-v2-and-execution-backends.md#7-n8n-activepieces-and-other-engines)).
- **Exporting device steps, browser steps and `opaque_workflow` connections** (`export_unsupported`).
- **Human approval nodes inside the exported workflow** (for example Slack "Send and Wait for Response"). The card
  says the export does not ask before each batch.
- **Web and Mac screens** for the export card, download and push (M8 web, M5 Mac tasks).
- **Changes to m5-10's packages.** This slice imports `@offload/execution-backend`; if it needs a change there, it
  goes back to m5-10's owner as a "Scope changes" note. In m5-10's deploy route it adds only the `n8n_pushed` check.

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
