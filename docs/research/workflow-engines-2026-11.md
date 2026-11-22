# Workflow engines for Offload fixes (research, 2026-11)

Research behind [ADR 0039](../adr/0039-routine-definition-v2-and-execution-backends.md). Words follow
[GLOSSARY.md](../GLOSSARY.md). Every external fact below was checked on **2026-11-22** at the URL next to it. Facts
marked **UNVERIFIED** could not be confirmed from a primary source that day. This is not legal advice; the license
reading is an engineer's reading of the published texts and needs counsel and, for n8n, the vendor's written answer
before anyone relies on it commercially ([OQ-32](../OPEN_QUESTIONS.md#oq-32-written-license-confirmation-from-n8n)).

**Owner decision, 2026-11-22** ([OQ-30](../OPEN_QUESTIONS.md#oq-30-n8n-in-offload)), verbatim: "Build worflow
automation as an expert n8n engineer". Sections 3.1, 6 and 7 were updated the same day for it: expert n8n practice
becomes workflow design rules, Offload exports verified fixes as n8n workflow JSON for the user's own n8n (with an
optional push), Offload's own engine stays the default runtime, and n8n run by Offload stays gated on n8n's written
answer.

## 1. The question

The owner, verbatim: "it should give well designed workflows maybe even through like n8n to automate things ... we
need stable workflows that are built and it needs to research the best tools to make those but n8n may allow that to
happen faster".

Today a fix is a routine artifact (`routine.json` plus pure transforms, [ADR 0026](../adr/0026-routine-artifact-contract.md))
built by the OK, build loop ([ADR 0012](../adr/0012-builder-policy-one-worker-held-out-fan-out.md)) and run by the
routine runtime on DBOS Transact ([ADR 0009](../adr/0009-durable-execution-on-postgres.md)). Connectors resolve MCP,
then Composio, then a direct API, then the browser, pinned at design time
([ADR 0033](../adr/0033-pinned-connector-resolution-and-launch-catalog.md)).

What a workflow engine could change splits into two roles, and the answer differs per role:

- **Execution backend**: the thing that runs a deployed fix (triggers, steps, retries, state).
- **Integration source**: where the knowledge and code for talking to an app come from (nodes, pieces, toolkits,
  MCP servers).

The owner's three needs map onto those roles: "stable workflows" is mostly the execution backend; "research the best
tools" and "faster" are mostly the integration source.

## 2. Hard constraints from decided ADRs

A candidate execution backend has to live with these, or the product changes:

1. **Every commit passes the gate** with an exact item hash, an item journal row written before the call, and
   `unknown` never retried ([ADR 0004](../adr/0004-every-external-action-is-gated.md)).
2. **Only the broker decrypts and uses credentials**, and it re-checks the approval and the item hash before a commit
   ([ADR 0034](../adr/0034-credential-broker-and-key-providers.md)).
3. **Durable state holds ids only** ([ADR 0009](../adr/0009-durable-execution-on-postgres.md)).
4. **Self-host needs Postgres 17 and S3-compatible storage, nothing else**; Offload Cloud and self-host are the same
   product ([ADR 0002](../adr/0002-stack-bun-typescript-hono-postgres.md),
   [ADR 0037](../adr/0037-hosting-cloud-and-self-host-parity.md)). A new runtime component needs an ADR.
5. **MIT core, commercial `ee/`**, and Offload Cloud hosts the product for paying teams
   ([ADR 0038](../adr/0038-license-mit-core-commercial-ee.md)). Code from AGPL, SSPL, BSL, Elastic or other
   non-permissive sources is never copied ([AGENTS.md](../../AGENTS.md#license-boundary-and-notices)).
6. **What was verified is what runs** (an n8n export keeps this only up to a shape check of its node bindings;
   [ADR 0039 section 9.3](../adr/0039-routine-definition-v2-and-execution-backends.md#93-validation)): pins fixed at design time, `definition_hash` bound by the deploy approval
   ([ADR 0032](../adr/0032-deploy-approval-binds-definition.md), [ADR 0033](../adr/0033-pinned-connector-resolution-and-launch-catalog.md)).
7. **No dry run** in product, API or copy. Verification is frozen checks, held-out check and replay of real
   instances inside the build ([ADR 0016](../adr/0016-no-dry-run.md)). This page says "replay" and "static
   validation" where the ask said "dry-run" and "dry validation".

Constraints 1 and 2 are the ones general-purpose automation engines break: n8n, Activepieces and Windmill each store
credentials and make the outbound call themselves, so Offload's broker and gate would not be in the call path.

## 3. Findings per candidate

### 3.1 n8n

**License.**
- The repo is under the Sustainable Use License 1.0. Its limitation section, verbatim: "You may use or modify the
  software only for your own internal business purposes or for non-commercial or personal use. You may distribute the
  software or provide it to others only if you do so free of charge for non-commercial purposes."
  ([LICENSE.md](https://github.com/n8n-io/n8n/blob/master/LICENSE.md)).
- Files with `.ee.` in the name or `.ee` in the directory name are under the n8n Enterprise License instead. It allows
  production use only "if you (and any entity that you represent) hold a valid n8n Enterprise license"
  ([LICENSE_EE.md](https://github.com/n8n-io/n8n/blob/master/LICENSE_EE.md)).
- The old license page `docs.n8n.io/sustainable-use-license/` returned "Page Not Found". The FAQ now lives at
  [docs.n8n.io/n8n-community-license/community-license/license-faq.md](https://docs.n8n.io/n8n-community-license/community-license/license-faq.md).
  The FAQ quotes below are from that page.

What the FAQ allows and forbids (all quotes checked 2026-11-22 at the FAQ URL above):
- **The page's bolded headline line**: "If workflows are only created or modified by you or people in your
  organization, you can use n8n under the Community license for free."
- **Scope**: it "applies to the self-hosted version of n8n only"; "n8n Cloud is a paid subscription with its own
  terms; this page doesn't apply to it." No public n8n Cloud terms page was found in the docs index that day
  (**UNVERIFIED**: Cloud terms).
- **Allowed**, as listed:
  - "Use n8n behind the scenes in your own product, where users can use and trigger the automations you built, and
    even connect their own accounts to them." Also: "Triggering or executing pre-built workflows via API or webhooks
    is fine."
  - "Build automations for your clients on your instance, as long as your clients do not have the possibility to
    create or edit them."
  - "Charge your customers for workflow creation, setup, and maintenance services."
  - "Consulting and automation services are explicitly permitted under the Sustainable Use License." The condition,
    for a consultant's own instance: "n8n remains your internal tool, where clients receive outputs, not access."
  - Under "Can I install and manage n8n on a client's own server?": "Yes, provided that you are not *also* hosting
    for them. Where a client runs n8n on their own infrastructure and needs consultancy or implementation services,
    you can charge the client for installing, configuring, building workflows, and maintaining n8n on their behalf.
    This is allowed as long as you don’t offer hosting as well, which would compete with n8n's own Cloud offering."
- **Not allowed**, as listed:
  - "Allow external end users to build or configure their own workflows through your product, whether via a custom
    UI, our API, MCP, or an AI agent acting on the user's behalf."
  - "Host n8n as a service and allow your clients to build workflows".
  - "Fork n8n's code to launch your own automation product" and "White-label n8n by removing our branding and
    offering n8n as is."
- **The test it applies**: "The key question is not whose credentials are used, but who controls the workflow
  logic." It is "medium-neutral: what matters is whether the end user determines the workflow logic", "not the
  interface used (UI, n8n API, MCP, or an AI agent acting for the user)." Also: "The SUL test is not about UI
  visibility — it is about who controls the workflow logic and whose commercial interests are being served." It
  "restricts use where the commercial value of a product derives entirely or substantially from n8n functionality."
- **Shipping n8n to a customer's own server**: "This is permissible, but it may sit in gray territory. Shipping n8n
  to your customers as part of a paid product comes with extra conditions under the license ... Confirm your
  architecture with license@n8n.io before launch."
- **Contacts**: "For licensing questions, contact" license@n8n.io; "To discuss a commercial license, contact"
  sales@n8n.io.
- **Not in the FAQ**: who owns workflow JSON a user creates. The FAQ covers a third party (a consultant) building
  workflows in a client's own n8n, but not a third-party *product* that generates them, by an AI, for many users.

The OEM route:
- The old Embed page `n8n.io/embed` returned 404. The docs now describe an OEM deployment that "requires a separate
  commercial agreement with n8n", with n8n branding required
  ([deploy-as-an-oem-integration](https://docs.n8n.io/deploy/host-n8n/deploy-as-an-oem-integration.md)).
- No public price. The [pricing page](https://n8n.io/pricing/) has no OEM line. **UNVERIFIED**: any OEM price.

**What that means for Offload**, path by path. Every one of these limits binds a *licensee* of n8n, about *its*
use of n8n ("through your product", "on your instance").
- **Hosted: n8n that Offload runs, building and running fixes for users** ("Offload builds and runs it inside n8n
  for you"). An Offload fix is a workflow built per user, from that user's work, by an AI acting for that user, and
  the user approves its logic: the end user determines the workflow logic. That is the FAQ's not-allowed case, so it
  needs an OEM or Enterprise agreement. **Gated** on n8n's written answer
  ([OQ-32](../OPEN_QUESTIONS.md#oq-32-written-license-confirmation-from-n8n)); not built.
- **Shipping n8n** in Offload's images: no. Free redistribution is limited to non-commercial purposes.
- **Export file** (decided, slice m5-12): Offload writes n8n workflow JSON with its own code; the user imports it into
  their own self-hosted n8n. Offload runs no n8n, ships no n8n code and is not an n8n licensee here. The user is the
  licensee and uses n8n "for your own internal business purposes", which the license allows.
  - For it: the client's-own-server answer lets a third party charge for "building workflows ... on their behalf" in
    the client's own n8n, as long as it does not also host n8n. Offload does not host n8n for the user.
  - Against it: that answer is written for consultancy, not for a product that generates workflows by AI for many
    users. And the bolded headline grants free use "If workflows are only created or modified by you or people in
    your organization". These workflows are created by Offload, so the headline does not plainly cover the **user**,
    and the risk sits with the user's own license as well as with Offload. (The "clients receive outputs, not
    access" condition is about a consultant's own instance and does not apply: here the user owns the instance.)
  - Residual risk: **moderate, unconfirmed**. n8n could also argue the commercial-value clause, though that clause
    restricts use of n8n, which Offload does not use here. Asked in writing in OQ-32; the export card tells the user.
- **Push to the user's own instance** (decided, slice m5-12, ships off): Offload calls the user's n8n public API with
  the user's API key to create and optionally publish the approved JSON. The user is still the licensee of that
  instance and the workflow serves their own business, so on our reading the "through your product" limit is not
  triggered: there is no n8n of Offload's for the user to build on. But the not-allowed sentence names exactly this
  medium ("our API ... an AI agent acting on the user's behalf"), and the test is "medium-neutral". The user-side
  headline point above applies too. Residual risk: **real**. A user on n8n Cloud is under terms we have not read. So
  push ships switched off until n8n confirms in writing (OQ-32).
- **Calling workflows a customer built themselves** in their own n8n, as tools, matches "Triggering or executing
  pre-built workflows via API or webhooks is fine". n8n can expose one workflow as an MCP server through its MCP
  Server Trigger node
  ([mcptrigger](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-langchain.mcptrigger.md)), so Offload
  can reach it as an ordinary MCP connection.

**Product facts.**
- **API**: public REST API on every self-hosted edition, not on the free trial
  ([n8n API](https://docs.n8n.io/api/), served at `docs.n8n.io/connect/n8n-api.md`). Auth is the `X-N8N-API-KEY`
  header ([authentication](https://docs.n8n.io/connect/n8n-api/authentication.md)). Workflow routes include create,
  update, `publish`/`unpublish` (activate/deactivate are deprecated) and history
  ([workflows](https://docs.n8n.io/connect/n8n-api/build-and-run/workflows.md)). There are also executions (list,
  stop, retry) and credentials routes.
- **API details for a push** ([workflows](https://docs.n8n.io/connect/n8n-api/build-and-run/workflows.md), checked
  2026-11-22):
  - "The n8n API is available on: ... Self-hosted: All editions"; "It isn't available on the free trial."
  - Base path `https://<your-instance-url>/api/v1`; "Send the API key in your API call as a header named
    `X-N8N-API-KEY`." "Scopes are available on all plans from n8n 2.14.0"; before that, non-Enterprise keys "have
    full access to all the account's resources and capabilities."
  - `POST /workflows` requires `name`, `nodes`, `connections`, `settings`; also accepts `pinData` ("Pinned sample
    data for nodes, keyed by node name"), `staticData` and others. `id`, `active`, `tags`, `meta` and other fields are
    `readOnly`. The request schema has `additionalProperties: false`, at the top and on each node.
  - `POST /workflows/{workflowId}/publish`: "Publish a workflow. In n8n v1, this action was termed activating a
    workflow." `/activate` is "Deprecated: use POST /workflows/{id}/publish instead." The authentication page still
    names `/activate` and `/deactivate`; the reference is newer.
  - The reference index says a POST can be retried "with an `Idempotency-Key` header", and "The reference matches the
    latest stable n8n release."
- **Reliability**:
  - Error workflows: "For each workflow, you can set an error workflow in Workflow Settings. It runs if an execution
    fails." It "must start with the" Error Trigger
    ([handle errors](https://docs.n8n.io/build/flow-logic/handle-errors-gracefully.md)). API setting
    `settings.errorWorkflow`: "The ID of the workflow that contains the error trigger node."
  - Node settings: "Retry On Fail: When an execution fails, the node reruns until it succeeds." On Error has "Stop
    Workflow", "Continue" and "Continue (using error output)"
    ([nodes](https://docs.n8n.io/build/understand-workflows/workflow-components/work-with-nodes.md)). The API node
    schema has `retryOnFail`, `maxTries`, `waitBetweenTries`, `onError`; `continueOnFail` is deprecated ("use onError
    instead"). **UNVERIFIED**: units and limits of `maxTries` and `waitBetweenTries` (no docs page gives them).
  - Timeouts: workflow setting Timeout Workflow, API `settings.executionTimeout` (**UNVERIFIED**: its unit in the API);
    HTTP Request "Timeout ... in milliseconds"
    ([HTTP Request](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.httprequest.md)).
  - Dedupe across runs: Remove Duplicates has "Remove Items Processed in Previous Executions", scope Node or
    Workflow, "Value to Dedupe On"; "By default, n8n stores 10,000 items"
    ([Remove Duplicates](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.removeduplicates.md)).
  - Time zones: "If you don't configure the workflow or instance timezone, n8n defaults to the EDT (New York)
    timezone" ([workflow settings](https://docs.n8n.io/build/manage-workflows/configure-workflow-settings.md)); the
    Schedule Trigger takes a "Custom (Cron)" expression and uses the workflow time zone if set
    ([Schedule Trigger](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.scheduletrigger.md)). The
    page is ambiguous about a sixth (seconds) cron field; the export emits five fields.
  - Code node: "Run Once for All Items" (default) or "Run Once for Each Item"; JavaScript; "You can't access the file
    system or make HTTP requests"
    ([Code](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.code.md)). **UNVERIFIED** in the
    docs read: the exact `$input.all()` syntax; the m5-12 live test confirms the wrapper.
  - Error Trigger: "You have to publish the workflow that uses the Error Trigger node"; "You can't test error
    workflows when running workflows manually"
    ([Error Trigger](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.errortrigger.md)).
  - Idempotency: "Idempotency for the n8n API is available from n8n 2.45.0 on"; "n8n keeps the first successful
    response for 12 hours from when you send the key"; "After 12 hours, the same key runs the POST again and can
    create a duplicate"; "Keys belong to the user, not to one API key"
    ([idempotency](https://docs.n8n.io/connect/n8n-api/idempotency.md)). The publish route's reference lists no
    idempotency header.
  - Code node modules: "If you self-host n8n, you can import and use built-in and external npm modules in the Code
    node"; "If you use n8n Cloud, you can't import external npm modules"
    ([Code](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.code.md)).
  - Human approval inside n8n exists per app, for example Slack "Send and Wait for Response"
    ([Slack approvals](https://docs.n8n.io/integrations/builtin/app-nodes/n8n-nodes-base.slack/approvals.md)). The
    export does not add one by default. Queue mode with Redis and workers is in the community edition; multi-main is paid
  ([community edition features](https://docs.n8n.io/deploy/host-n8n/community-edition-features.md)).
- **Plan limits**:
  - Full workflow history is Enterprise only; "Versions from the last 24 hours are available for all users"
    ([change history](https://docs.n8n.io/build/manage-workflows/view-change-history.md)).
  - Git source control is Business and Enterprise
    ([source control](https://docs.n8n.io/administer/use-source-control-and-environments.md)).
  - "Data pinning isn't available for production workflow executions"; "You can only pin data for nodes that have a
    single main output"; "You can't pin data if the output data includes binary data"
    ([pin and mock data](https://docs.n8n.io/build/work-with-data/pin-and-mock-data.md)).
- **Generation and validation**:
  - "n8n saves workflows in JSON format." Exported files "include" credential names and IDs, and "HTTP Request nodes
    may contain authentication headers when imported from cURL"
    ([export and import](https://docs.n8n.io/build/manage-workflows/export-and-import.md)). The page does not say
    that secret values are left out; Offload's export carries no credential id, name of the user's real credential or
    header value at all.
  - Node versions: "If a user builds and saves a workflow using version 1, n8n continues to use version 1 in that
    workflow" ([node versioning](https://docs.n8n.io/connect/create-nodes/build-your-node/reference/versioning.md)).
    The API schema has `type` (string) and `typeVersion` (number) on each node, without a description.
  - The Workflow SDK (from 2.12.0) turns code into workflow JSON "and validates it"
    ([workflow SDK](https://docs.n8n.io/connect/workflow-sdk.md)).
  - The instance-level MCP server has tools such as `create_workflow_from_code` and `validate_node_config`
    ([MCP server](https://docs.n8n.io/connect/connect-to-n8n-mcp-server.md)).
  - **UNVERIFIED**: a standalone published JSON Schema for workflow files (none found).
- **Coverage**: "Browse 2,000+ integrations" ([integrations](https://n8n.io/integrations/)).
- **Versions**:
  - Latest GitHub release n8n@2.48.7 (2026-11-20).
  - n8n 3.0 is "currently available as an early access release" and drops npm installs
    ([v3.0 breaking changes](https://docs.n8n.io/changelog/v30-breaking-changes.md)).
  - 2.0 (2025-12-05) made task runners the default and replaced activate with publish
    ([v2.0 breaking changes](https://docs.n8n.io/changelog/v20-breaking-changes.md)).

### 3.2 Activepieces

- **License**: split. Everything outside `packages/ee/` and `packages/server/api/src/app/ee` "is available under the
  "MIT Expat" license" ([LICENSE](https://github.com/activepieces/activepieces/blob/main/LICENSE)). The `ee` code
  "may only be used in production, if you ... have a valid Activepieces Enterprise license"
  ([packages/ee/LICENSE](https://github.com/activepieces/activepieces/blob/main/packages/ee/LICENSE)). The pieces
  (integrations) live outside `ee`, so they are MIT by that file.
- **Embedding** is sold separately: "Embed From $36k a year ... White-label builder · One SDK"
  ([pricing](https://www.activepieces.com/pricing)). Hosting the MIT community edition yourself is allowed by MIT;
  the embed SDK and enterprise features are not.
- **Coverage**: the README says "All our pieces (280+) are available as MCP"; the live catalogue says "777 pieces
  today, with 7,023 actions between them" ([pieces](https://www.activepieces.com/pieces)). The two counts disagree;
  the catalogue is newer.
- **Reliability**: checkpointed steps, "At-least-once, not exactly-once"
  ([crash recovery](https://www.activepieces.com/docs/install/guarantees/crash-recovery.md)). Draft and locked
  published versions ([versioning](https://www.activepieces.com/docs/flows/versioning.md)). Retry "From failed step"
  on the run's own version ([debugging runs](https://www.activepieces.com/docs/flows/debugging-runs.md)).
- **Components**: App, Worker, Postgres and "Redis: Powers the queue using BullMQ"
  ([architecture](https://www.activepieces.com/docs/install/architecture/overview.md)).
- **UNVERIFIED**: flow-level mocking or replay for tests; whether the flow JSON schema is published as JSON Schema.

### 3.3 Windmill

- **License** ([LICENSE](https://github.com/windmill-labs/windmill/blob/main/LICENSE)):
  - Backend and frontend are AGPLv3, except enterprise code under a proprietary license.
  - The Community Edition images include proprietary code you may not "sell, resell, serve as a managed service,
    modify or wrap under any form without an explicit agreement".
  - To "build a feature on top of "Windmill Community Edition" that you sell commercially or embed in a distributable
    product or binary, you must get a commercial license".
  - "The openapi files, including the OpenFlow spec is Apache 2.0 Licensed."
- **Reliability**: constant and exponential retries ([retries](https://www.windmill.dev/docs/flows/retries)); an
  error handler after the last retry ([error handler](https://www.windmill.dev/docs/flows/flow_error_handler));
  "A Postgres database, which contains the entire state of Windmill, including the job queue"
  ([self-host](https://www.windmill.dev/docs/advanced/self_host)).
- **Testing**: "Mocking: Set a custom return value... Pinning: Use a previous successful run result"
  ([step mocking](https://www.windmill.dev/docs/flows/step_mocking)).
- **Format**: OpenFlow, "an open standard for defining "Flows"", with a `failure_module`
  ([OpenFlow](https://www.windmill.dev/docs/openflow)).
- **Versioning**: one deployed version per flow path; a new deployment overwrites it
  ([draft and deploy](https://www.windmill.dev/docs/core_concepts/draft_and_deploy)).
- **UNVERIFIED**: integration count.

### 3.4 Temporal

- **License**: server MIT ([LICENSE](https://github.com/temporalio/temporal/blob/main/LICENSE)); TypeScript SDK MIT
  ([LICENSE](https://github.com/temporalio/sdk-typescript/blob/main/LICENSE)).
- **Versioning**: `patched()` / `deprecatePatch()` and Worker Versioning
  ([versioning](https://docs.temporal.io/develop/typescript/versioning)).
- **Replay testing**: `worker.runReplayHistory`, "Fail CI if any error is encountered during replay"
  ([testing suite](https://docs.temporal.io/develop/typescript/testing-suite.md)).
- **Ops**: "four independently scalable services" ([server](https://docs.temporal.io/temporal-service/temporal-server.md));
  Cassandra, PostgreSQL or MySQL ([persistence](https://docs.temporal.io/temporal-service/persistence));
  Elasticsearch "Recommended for any setup that spawns more than a few Workflow Executions"
  ([visibility](https://docs.temporal.io/self-hosted-guide/visibility)).
- **Cloud**: "start at $50 per million Actions" ([pricing](https://temporal.io/pricing)).
- **Fit**: a code-first engine with no connectors. It would replace DBOS, not add integrations.
  [ADR 0009](../adr/0009-durable-execution-on-postgres.md) already rejected it as a second system to run.

### 3.5 DBOS Transact (already chosen)

- **License and version**: MIT ([LICENSE](https://github.com/dbos-inc/dbos-transact-ts/blob/main/LICENSE)). npm
  `@dbos-inc/dbos-sdk` latest is 5.6.0; the repo pins 5.5.0 from the m1-01 spike.
- **Step retries**: `retriesAllowed` (default false), `maxAttempts` (default 3), `backoffRate` (default 2), `timeoutMS`
  ([steps](https://docs.dbos.dev/typescript/tutorials/step-tutorial)).
- **Versioning**: application version is a hash of workflow source. DBOS "only recovers workflows whose version
  matches the current application version"; `DBOS.patch()` handles in-place changes
  ([upgrading workflows](https://docs.dbos.dev/typescript/tutorials/upgrading-workflows.md)). Offload's rule that
  workflows end at every human wait keeps this cheap.
- **Fork**: `DBOS.forkWorkflow` re-runs from a chosen step
  ([workflow management](https://docs.dbos.dev/typescript/tutorials/workflow-management.md)).
- **Commercial parts Offload does not use**:
  - Conductor: "Self-hosted Conductor is released under a proprietary license and requires a license key"
    ([hosting Conductor](https://docs.dbos.dev/conductor/self-hosting/hosting-conductor.md)).
  - `@dbos-inc/dbos-enterprise` is under the Conductor license
    ([Transact Enterprise](https://docs.dbos.dev/explanations/transact-enterprise.md)).
  - Offload's schedules, purge and monitoring are its own code
    ([ADR 0009 spike result](../adr/0009-durable-execution-on-postgres.md#spike-result)), so neither is needed.
    Adding either later would need an ADR.

### 3.6 Composio

- **What it is**: an integration platform for agents: "1000+ pre-authenticated toolkits" in the
  [README](https://github.com/ComposioHQ/composio), "1,700+ apps" on the
  [pricing page](https://composio.dev/pricing/platform). The two counts disagree.
- **Licenses**: the SDK repo is MIT. The npm package `@composio/core` 0.31.0 declares ISC. Offload calls the REST API
  from the broker and uses no Composio SDK ([ADR 0033](../adr/0033-pinned-connector-resolution-and-launch-catalog.md)),
  so neither matters at run time.
- **Self-host**: an "Enterprise arrangement"
  ([token custody](https://docs.composio.dev/docs/security/token-custody.md)).
- **MCP**: "Every session also exposes a hosted MCP endpoint" (README).
- **Fit**: Composio is an integration source (rung 2), not an execution backend. Unchanged.

### 3.7 MCP-first connectors

- **Current spec**: "The current protocol version is 2026-07-28"
  ([versioning](https://modelcontextprotocol.io/specification/versioning.md)).
- **Tasks**: 2025-11-25 added experimental tasks for "durable requests with polling and deferred result retrieval"
  ([changelog](https://modelcontextprotocol.io/specification/2025-11-25/changelog.md)). 2026-07-28 moved them to the
  official extension `io.modelcontextprotocol/tasks` and made the protocol stateless
  ([changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog.md)).
- **No orchestration**: MCP defines tools, resources and prompts. It has no step graphs and no durable multi-step
  runs (inferred from the spec index).
- **Registry**: "currently in preview. Breaking changes or data resets may occur before general availability"
  ([registry](https://modelcontextprotocol.io/registry/about.md)).
- **Fit**: MCP is the rung-1 integration source and stays first. The tasks extension is relevant for long-running
  tool calls: a commit whose result comes later must still end in `sent`, `failed_before_send` or `unknown` in the
  item journal.

### 3.8 Others, not scored

- **Kestra**: Apache-2.0 ([LICENSE](https://github.com/kestra-io/kestra/blob/develop/LICENSE)); declarative YAML flows.
- **Trigger.dev**: Apache-2.0 ([LICENSE](https://github.com/triggerdotdev/trigger.dev/blob/main/LICENSE)); TypeScript
  tasks with retries and queues.

Both are separate platforms that hold their own credentials. They raise the same gate and broker problem as the
scored engines and add a server.

## 4. Scored matrix: execution backend

Scores are 0 to 5 per criterion. Total = Σ (weight × score) ÷ 5, so 100 is the maximum. The weights sum to 100 and
are this page's judgement, stated so they can be argued with. The arithmetic was run in code
(`Σ w·s` then `÷ 5`).

| Criterion | Weight | What a 5 means |
|---|---|---|
| Stability | 15 | Durable steps, retries with backoff, error handling, version pinning, recovery after crash |
| Gate and broker fit | 15 | Commits go through Offload's gate, item journal and broker with no change to [ADR 0004](../adr/0004-every-external-action-is-gated.md) and [ADR 0034](../adr/0034-credential-broker-and-key-providers.md) |
| Self-host and Cloud parity | 15 | Runs on Postgres and object storage only, same in both modes ([ADR 0037](../adr/0037-hosting-cloud-and-self-host-parity.md)) |
| License | 20 | Offload may ship it in images and host it for paying teams, with MIT core and commercial `ee/` |
| Generation and validation | 10 | A small, published, machine-checkable format a model can write and code can validate before running |
| Integration coverage | 10 | Integrations the engine brings by itself |
| Testability | 10 | Replay of recorded reads, mocks, held-out checks, run in CI |
| Operational cost | 5 | No extra servers, queues or search clusters |

| Candidate (role: execution backend) | Stab. | Gate fit | Parity | License | Gen. | Coverage | Test. | Ops | **Total** |
|---|---|---|---|---|---|---|---|---|---|
| **Native: `routine.json` on DBOS Transact** | 4 | 5 | 5 | 5 | 4 | 3 | 5 | 5 | **91** |
| Temporal, self-hosted | 5 | 4 | 1 | 5 | 2 | 1 | 5 | 1 | **67** |
| n8n, customer-run, Offload deploys fixes into it by API | 4 | 1 | 3 | 2 | 4 | 5 | 3 | 3 | **59** |
| Activepieces CE, hosted by Offload | 4 | 1 | 2 | 4 | 3 | 5 | 2 | 2 | **59** |
| Windmill CE, hosted by Offload | 5 | 2 | 3 | 1 | 4 | 3 | 4 | 3 | **59** |
| n8n CE, hosted by Offload | 4 | 1 | 2 | 0 | 4 | 5 | 3 | 2 | **47** |

The n8n export (decided 2026-11-22) is not in this table: it is an export target, not an execution backend. A fix
exported to the user's n8n runs outside Offload, so the "gate fit" row of "n8n, customer-run" describes it, and the
user, told so in words, chooses it per fix.

Why the scores:
- **Native**:
  - Stability 4, not 5: DBOS gives durable steps and step retries, but error handling, read-shape drift and the
    stability record are Offload's own code to write. [ADR 0039](../adr/0039-routine-definition-v2-and-execution-backends.md)
    adds them.
  - Coverage 3: it brings no integrations; they come from the connector layer, which every row would also need.
  - Scored as designed; most of it is not built yet (the runtime is M2 task m2-10).
- **Temporal**: the best durability and replay testing on the list. But it is four services plus a database, with
  Elasticsearch recommended. Workflows are code, not data a user can read and approve.
- **n8n, customer-run**:
  - Gate fit 1: n8n holds the credentials and makes the call, so the broker cannot re-check item hashes and the
    journal cannot be written before the call.
  - License 2: the FAQ's gray territory, unconfirmed.
  - Parity 3: identical in both Offload modes, but only for users who run n8n.
- **Activepieces**: the cleanest license of the integration-rich engines (MIT community edition, MIT pieces). Same
  credential problem; adds Redis and workers.
- **Windmill**: strong engine, Postgres-backed. AGPL plus proprietary bits in the community images means a
  commercial license to build a paid feature on it.
- **n8n hosted by Offload**: license 0, because the FAQ forbids exactly this use without an OEM or Enterprise
  agreement. A 0 on license disqualifies a row whatever its total.

## 5. Integration sources

These are not scored against the backends because they are not alternatives to them. Offload needs one execution
backend and several integration sources.

| Source | License or terms | How Offload may use it | Rung ([ADR 0033](../adr/0033-pinned-connector-resolution-and-launch-catalog.md)) |
|---|---|---|---|
| First-party and vetted remote MCP servers | per server | As today | 1 |
| A customer's own n8n workflows exposed through the MCP Server Trigger | the customer's own SUL use; "Triggering or executing pre-built workflows via API or webhooks is fine" | An MCP connection the customer adds, always `opaque_workflow`. Offload writes n8n workflows only as an n8n export the customer imports or approves a push of ([OQ-30](../OPEN_QUESTIONS.md#oq-30-n8n-in-offload)); it cannot see later edits | 1 |
| Activepieces pieces as MCP servers | MIT pieces; the MCP server runs in the customer's Activepieces | An MCP connection the customer adds | 1 |
| Composio toolkits | proprietary service, MIT/ISC SDK | As today, REST from the broker, allowlists, retention disclosed | 2 |
| Activepieces pieces as source code | MIT, with `NOTICE` | Ported, a piece at a time, into allowlisted direct-API adapters run by the broker. Never executed as third-party code inside the broker. Spike S8 | 3 |
| n8n node source | SUL | **No.** Not a compatible license ([AGENTS.md](../../AGENTS.md#license-boundary-and-notices)); n8n's public docs may be read for API facts | |
| Vendor OpenAPI descriptions | per vendor | As today | 3 |

## 6. Verdict

1. **Keep the native backend.** Run fixes as `routine.json` on DBOS Transact behind a backend port. It is the only
   candidate that keeps the gate, the item journal, the broker and Postgres-only self-host as they are. Make it more
   stable in Offload's own code: per-step retry policies on top of DBOS step retries, timeouts, bounded per-item
   error handling, explicit dedupe keys, read-shape drift checks, versions with rollback, and a stability record.
   ([ADR 0039](../adr/0039-routine-definition-v2-and-execution-backends.md).)
2. **Do not host or ship n8n.** Its license forbids Offload's use case on Offload-run n8n without an OEM or Enterprise
   agreement. Its execution model would also bypass the broker and the gate.
3. **Build like an expert n8n engineer, and export to n8n** (owner decision of 2026-11-22):
   - Eight workflow design rules (explicit triggers; small, single-purpose steps; error workflows and branches;
     per-step retries and timeouts; idempotent writes; credentials by reference; pinned-data tests; held-out
     acceptance before activation), enforced by lint on every routine definition and every export
     ([ADR 0039 section 3.4](../adr/0039-routine-definition-v2-and-execution-backends.md#34-workflow-design-rules)).
   - An n8n export of each verified fix for the user's own n8n, through node bindings whose shapes are checked against
     the pinned n8n release, a schema and a pinned node catalog, with `pinData` from the tokenised fixtures (write nodes
     pinned too), labelled as running outside Offload's gate and saying what was not verified; and a push to the user's
     own instance by its API, built but switched off until n8n answers in writing
     ([ADR 0039 section 9](../adr/0039-routine-definition-v2-and-execution-backends.md#9-the-n8n-export)).
   - A user can also connect their own n8n workflows to Offload as MCP tools, as before.
   - n8n run by Offload for users stays gated
     ([OQ-32](../OPEN_QUESTIONS.md#oq-32-written-license-confirmation-from-n8n)).
4. **"Faster" comes from integration sources, not a second engine**: MCP servers (including Activepieces' and the
   user's own n8n), Composio, and MIT Activepieces pieces as a source for direct-API adapters.
5. **"Research the best tools" becomes a code-ranked tool choice per capability** in the fix designer. A model may
   name candidates from catalogs; code filters and orders them by ADR 0033's rungs, verification, existing
   connections and measured failure rates. The record is shown in words.

## 7. License risks, stated plainly

- **n8n**:
  - Hosting or embedding it for paying users without an agreement breaches the SUL. The license "will automatically
    terminate" on violation (LICENSE.md).
  - Export file to the user's own n8n: moderate residual risk, unconfirmed (section 3.1). The FAQ lets a third party
    build workflows in a client's own n8n ("you can charge the client for installing, configuring, building
    workflows, and maintaining n8n on their behalf"), but its headline grants free use only "If workflows are only
    created or modified by you or people in your organization". That is a risk to the **user's** free use, not only
    to Offload; the export card says so and OQ-32 asks n8n.
  - Push into the user's own n8n by its API: real residual risk, because the FAQ's not-allowed sentence names "our API"
    and "an AI agent acting on the user's behalf" and calls its test medium-neutral. Built, but off until n8n answers
    in writing ([OQ-32](../OPEN_QUESTIONS.md#oq-32-written-license-confirmation-from-n8n), owner action: ask
    license@n8n.io). n8n Cloud users are under terms not reviewed here.
  - Hosted n8n for users: needs an agreement; gated, not built.
  - Do not port n8n node code, and do not run or ship n8n's Workflow SDK or MCP server inside Offload. The node
    catalog holds interface facts (type names, versions, parameter keys) from public docs, checked on a live instance.
  - `LIVE:` tests run against an n8n instance the operator runs for internal testing only.
- **Activepieces**:
  - MIT pieces need a `NOTICE` entry and the copyright line kept.
  - Never take code from `packages/ee/` or `packages/server/api/src/app/ee`.
  - Check each piece's folder for its own license before porting.
- **Windmill**: AGPL and proprietary community images. Do not copy code. The OpenFlow spec text is Apache-2.0 and
  may inform ideas.
- **Composio**: proprietary service. Payload logging by default is already disclosed
  ([ADR 0033](../adr/0033-pinned-connector-resolution-and-launch-catalog.md)). SDK license metadata disagrees (MIT
  repo, ISC npm); irrelevant while no SDK ships.
- **DBOS**: the MIT core is used. Conductor and Transact Enterprise are proprietary; using them would need an ADR and
  would make self-host depend on a commercial key.
- **MCP**: open spec. Each server has its own terms; a server's tool behaviour can change without its pin changing
  when the server is a front for workflows (n8n, Activepieces), which is a disclosure item, not a license one.
