# Roadmap

Milestones in order. Each has scope, exit criteria and named acceptance tests. A milestone is done when every
acceptance test exists, ran red first, and now passes in `scripts/verify-all.sh` (or the CI `mac` job for Swift), and
the owner has seen the exit demo. Words follow [GLOSSARY.md](GLOSSARY.md).

**Sequencing.** The riskiest, least-proven half (artifact contract, fixtures, connectors, gate, deploy, run) goes
first, on a task Muhammad types in: the **hand-fed loop** (M2). Capture is mostly ported code and runs **in parallel**
(M3) on disjoint paths. M4 closes the loop with a measured saving. M5 lets observed work feed the same build path.
Everything else widens it.

| Step | Milestones | Proves |
|---|---|---|
| 0 | M0, M1 | Operator items with lead times started; spikes; foundations (durable runtime, contracts, tenancy, login, routine contract) |
| A | M2 | The whole build and run half on one real task |
| C (parallel with A) | M3 | Capture to cloud, signed Mac app with Sparkle |
| B | M4 | Loop closed end to end with hs-1 |
| D | M5 | Observed opportunities feed the same build path |
| later | M6 to M9 | Depth, user model, Pro, Enterprise |

Kept small until a second tenant exists: one process (`offload serve`) plus the broker, one tenant row with RLS on,
one OIDC provider or magic link, TypeScript policy rules. Deferred: fan-out beyond one retry (M6), Cedar (M9), WorkOS
(M8), workspaces UI (M8), the Offload MCP server (M8), outbound webhooks (M8), keyframes upload (M5), entities and
facts (M7), month and quarter records (M7), Helm (M8), all of `ee/` (M8, M9).

Test naming: `TAG: sentence` inside the package's `tests/<slice-id>/` folder, as in
[AGENTS.md](../AGENTS.md#slice-format). Swift slices use a suite named after the slice (for example `M302`) in
`apps/mac/Tests/OffloadMacTests/<suite>/`. Slice specs exist for M1, M3 and the Wave 1 slices m2-02, m2-03, m2-12,
m3-03 and m5-03; [WAVE1.md](WAVE1.md) maps the old plan's Wave 1 workstreams (PR #42 W1-A to W1-H) to these slices,
with owners and the operator items each waits on. Other tasks are listed in the format
id, depends on, tier, size, parallel group, paths: the same fields as the slice front-matter (`model_tier`, `size`,
`parallel_group`, `owns`; [AGENTS.md](../AGENTS.md#slice-format)). Tier: Opus plans and reviews, Sonnet implements.
Size: S (under a day), M (1 to 2 days), L (3 to 5 days). Parallel group: `M<milestone>-<letter>`, run in letter order;
tasks in one group can run at the same time if their slices are `parallel_safe`. The slices use groups `M1-A` to
`M1-D`, `M2-A`, `M3-A` to `M3-C` and `M5-A`.

## M0. Harness, architecture, operator items and spikes

- **Scope**: docs, ADRs, monorepo skeleton, CI stub, harness scripts, slice template, M1 and M3 slice specs; the
  operator items below started; the spikes below scheduled.
- **Exit criteria**: `scripts/verify-all.sh` green on the Linux box; every doc link resolves; core never imports `ee/`;
  operator items O1, O2, O4, O5, O6, O7, O8, O12 and O14 started (their lead times run while M1 is built).
- **Acceptance tests** (exist now):
  - `scripts/tests/license-boundary.test.ts`: passes clean core; fails on static import, relative path, dynamic import, manifest dependency.
  - `scripts/tests/doc-links.test.ts`: GitHub-style slugs; fails on a missing target.
  - `scripts/tests/copy-lint.test.ts`: dry-run terms fail in any product source; banned words and em dashes fail only
    in user-visible strings, with word boundaries (a Keychain identifier containing "Unlock" passes).
  - `scripts/tests/slices-lint.test.ts`: front-matter keys incl. `model_tier`, `size`, `parallel_group`, `owns`;
    `depends_on` names real slices; `verify.sh` reads its config from the SPEC; `in_progress` needs `BASE`; `done`
    slices run with `SKIP_FULL_SUITE=1`.
  - `scripts/tests/workflows.test.ts`: every CI workflow parses as YAML and has jobs with steps.
  - one `tests/smoke.test.ts` per workspace package.

### Operator items

Only the owner can do these. Lead times are typical, not promises; check each when starting it.

| # | Item | Lead time | Needed by |
|---|---|---|---|
| O1 | Apple Developer Program enrolment for consultance.ai as an organisation (needs a D-U-N-S number). Decided 2026-11-14: the owner enrols himself and is the Account Holder ([OQ-16](OPEN_QUESTIONS.md#oq-16-mac-distribution-and-signing) (b)) | days to weeks | M3 (signed app); start in M0 |
| O2 | Lock the bundle id: `ai.offload.mac`, dev builds `ai.offload.mac.dev` ([OQ-16](OPEN_QUESTIONS.md#oq-16-mac-distribution-and-signing)) | minutes, a decision | M3; before any signed build reaches a tester |
| O3 | Developer ID certificate and notarization credentials stored as CI secrets | a day, after O1 | M3 |
| O4 | Re-authenticate the GitHub token with the `workflow` scope. The old repo's CI workflow files could not be pushed because the token lacks it, so the macOS CI build (PR #41 `mac-release.yml`, PR #45 `builder-mac.yml.proposed`) is blocked until this is done | minutes | M0 (CI `mac` job) |
| O5 | Google Cloud project and an OAuth client marked Internal to your Workspace (Gmail, Calendar, Sheets, Drive scopes; also the M1 login client) | hours | M1 (login), M2 (connectors) |
| O6 | E2B account and API key | hours | M2 exit |
| O7 | Cloud host account and region ([OQ-01](OPEN_QUESTIONS.md#oq-01-cloud-hosting-provider-and-region)) | a day | M1 deploy |
| O8 | Anthropic API organisation for Offload with a spend limit ([OQ-05](OPEN_QUESTIONS.md#oq-05-model-provider-terms-and-monthly-model-budget)) | hours | M2 |
| O9 | Composio project with a toolkit allowlist; zero-retention add-on before any second user | weeks (vendor) | M2 if a Composio app is used; M8 |
| O10 | Anthropic zero data retention agreement | weeks (vendor, unknown) | before any second user (M8) |
| O11 | Sparkle EdDSA signing key and appcast host | hours | M3 |
| O12 | CI capacity for macOS. Default revised for the public repo: hosted `macos-26` for PR jobs and releases, no self-hosted runner for `pull_request` jobs ([OQ-25](OPEN_QUESTIONS.md#oq-25-ci-capacity-for-macos)) | same day | M0 (CI `mac` job) |
| O13 | Product domain (`api.`, `downloads.`) and TLS | a day | M1 deploy, M3 (appcast) |
| O14 | Rotate the provider key that old `LAUNCH.md` lists as exposed, and confirm old test canaries are fake | same day | M1 (first port, m1-03) |
| O15 | Privacy policy, terms and sub-processor list ([OQ-17](OPEN_QUESTIONS.md#oq-17-privacy-policy-terms-and-dpa)): a plain-language version for the tenant of one, counsel-reviewed before any second user | weeks | M3 (linked from "What leaves your Mac"); M8 (reviewed) |
| O16 | Create the public repository `tabani-png/offload-v2` and push, after the checklist in [DEPLOYMENT section 6.5](DEPLOYMENT.md#65-before-the-public-push) ([OQ-27](OPEN_QUESTIONS.md#oq-27-publish-the-repository-publicly)). Agents never do this | an hour | M0 (when the owner chooses) |

### Spikes

| # | Spike | Time box | Result goes to |
|---|---|---|---|
| S1 | TCC attribution: observer as a child of the app, `SMAppService` login item, grants survive a rebuild with a stable bundle id | 1 day | [ADR 0006](adr/0006-metadata-first-capture.md) |
| S2 | Screen-capture re-consent cadence on macOS 15 and 26 for our capture pattern | runs during M3 | [ADR 0006](adr/0006-metadata-first-capture.md) |
| S3 | DBOS Transact on Bun: slice [m1-01](../slices/m1-01-durable-spike/SPEC.md) | 1 day | [ADR 0009](adr/0009-durable-execution-on-postgres.md) |
| S4 | E2B egress allowlist (model proxy only) and a prebuilt image with a pinned dependency set | 1 day | [ADR 0011](adr/0011-sandboxed-build-workers.md) |
| S5 | OAuth and MCP for his real tools: Google internal client, Notion and Linear MCP registration, Stripe restricted key | 1 day | [ADR 0033](adr/0033-pinned-connector-resolution-and-launch-catalog.md) |
| S6 | `browser.step` mechanism (browser extension with native messaging, attended) | 2 days, before M6 | [ADR 0025](adr/0025-execution-placement-and-mac-actuator.md) |
| S7 | Transform isolate for routine artifacts (quickjs-emscripten candidate) | inside m1-05 | [ADR 0026](adr/0026-routine-artifact-contract.md) |

## M1. Foundations

Slices, in order: [m1-01](../slices/m1-01-durable-spike/SPEC.md) first (one day), then
[m1-02](../slices/m1-02-contracts-ingest/SPEC.md), then [m1-03](../slices/m1-03-tenancy-rls/SPEC.md) and
[m1-05](../slices/m1-05-routine-contract/SPEC.md) (same parallel group, one after the other because both write
`packages/testkit`), then [m1-04](../slices/m1-04-login-devices/SPEC.md).

- **Scope**: the durable runtime spike with its outcome written into ADR 0009; contracts (ingest envelope, five upload
  kinds, observation kinds, pseudonym shape, error envelope, Figure, JCS); Postgres tenancy with forced RLS, member
  isolation, resolver functions, roles, partitions and the audit chain writer; login with one OIDC provider or magic
  link, personal tenant on first login, device enrollment and device tokens (audiences `device` and `member`); the
  routine artifact contract in `packages/routine-sdk` with a fake connector in `packages/testkit`.
- **Exit criteria**: Muhammad logs in to his tenant of one and enrolls a device in a test harness; a two-step durable
  workflow survives a kill on the chosen runtime; a sample `routine.json` validates, hashes to a stable
  `definition_hash`, and runs against the fake connector returning commit items without any I/O.
- **Acceptance tests**:
  - `DURABLE: a two-step workflow killed between steps resumes once on Bun` (m1-01)
  - `DURABLE: a completed step is not re-run after restart` (m1-01)
  - `DURABLE: workflow input carries tenant_id and steps run inside withTenant` (m1-01)
  - `DURABLE: workflow inputs and messages hold ids only` (m1-01)
  - `DURABLE: recv longer than 15 minutes is refused` (m1-01)
  - `DURABLE: a scheduled workflow fires on its cron in a fake clock` (m1-01)
  - `DURABLE: cancel stops a sleeping workflow before its next step` (m1-01)
  - `DURABLE: purgeTenant removes every durable row of that tenant and no other` (m1-01)
  - `CONTRACT: observation_batch round-trips zod ↔ JSON Schema 2020-12` (m1-02)
  - `CONTRACT: unknown fields on an observation are rejected` (m1-02)
  - `CONTRACT: each observation kind enforces its required and allowed fields` (m1-02)
  - `CONTRACT: text over 8000 characters is rejected` (m1-02)
  - `CONTRACT: text_hash must equal sha256Hex(text)` (m1-02)
  - `CONTRACT: host with a path, port or scheme is rejected` (m1-02)
  - `CONTRACT: objects array of 501 is rejected` (m1-02)
  - `CONTRACT: ReviewEvent, NoticeAck, KeyframeMeta and StepResult validate their fixtures` (m1-02)
  - `CONTRACT: generated JSON Schemas are fresh` (m1-02)
  - `CONTRACT: every schema declares Draft 2020-12` (m1-02)
  - `CONTRACT: Figure requires arithmetic, evidence and a nullable source_purged_at` (m1-02)
  - `CONTRACT: Figure id is fig_ plus 16 hex of the JCS hash` (m1-02)
  - `CONTRACT: error envelope codes are the closed list in API.md` (m1-02)
  - `CONTRACT: receipt rejection codes are the closed list including not_enabled` (m1-02)
  - `JCS: canonical bytes match RFC 8785 test vectors` (m1-02)
  - `JCS: object key order does not change the hash` (m1-02)
  - `JCS: sha256Hex of a known string matches a fixed vector` (m1-02)
  - `KIND: the five upload kinds are accepted` (m1-02)
  - `KIND: run_outcome, baseline_sample and daily_aggregate are rejected` (m1-02)
  - `PSEUDO: the four pseudonym kinds with 16 hex are accepted` (m1-02)
  - `PSEUDO: a pseudonym with 15 hex, uppercase hex or an unknown kind is rejected` (m1-02)
  - `PSEUDO: router placeholders are accepted and other angle tokens are rejected` (m1-02)
  - `MIGRATE: migrations apply in order on an empty database` (m1-03)
  - `MIGRATE: a changed applied migration fails its checksum` (m1-03)
  - `MIGRATE: observations is partitioned by day with the day in the primary key` (m1-03)
  - `MIGRATE: an insert for a day with no partition lands in DEFAULT` (m1-03)
  - `MIGRATE: ensurePartitions forces RLS on every new partition` (m1-03)
  - `RLS: every tenant table has FORCE ROW LEVEL SECURITY` (m1-03)
  - `RLS: offload_app with tenant A reads zero rows of tenant B` (m1-03)
  - `RLS: with app.tenant_id unset offload_app reads zero rows` (m1-03)
  - `RLS: inserting a row for another tenant fails WITH CHECK` (m1-03)
  - `RLS: tenants is isolated by id` (m1-03)
  - `RLS: member B reads zero C1 rows of member A in the same tenant` (m1-03)
  - `RLS: member_scope tenant reads every member's rows` (m1-03)
  - `ROLE: offload_app cannot DELETE or UPDATE audit_events, audit_anchors or purge_log` (m1-03)
  - `ROLE: offload_app has no BYPASSRLS and owns no table` (m1-03)
  - `ROLE: resolver functions return ids only and nothing for unknown keys` (m1-03)
  - `ROLE: offload_jobs can list tenants and claim outbox rows and nothing else` (m1-03)
  - `ROLE: createPersonalTenant makes one tenant, one workspace, one owner` (m1-03)
  - `ROLE: removing the last owner throws LastOwnerError` (m1-03)
  - `ROLE: a fetch inside withTenant throws` (m1-03)
  - `AUDIT: appendAudit chains hash = sha256Hex(prev_hash + JCS(event))` (m1-03)
  - `AUDIT: two concurrent appends for one tenant produce one chain` (m1-03)
  - `AUDIT: an audit row rolls back with its transaction` (m1-03)
  - `AUDIT: an action not matching the pattern is refused` (m1-03)
  - `AUDIT: details with a string longer than 128 characters are refused` (m1-03)
  - `SESSION: first login creates a personal tenant with the member as owner` (m1-04)
  - `SESSION: second login reuses the tenant` (m1-04)
  - `SESSION: cookie is __Host- prefixed, httpOnly, Secure, SameSite=Lax` (m1-04)
  - `SESSION: a mutation without X-CSRF-Token is 403` (m1-04)
  - `SESSION: GET /v1/me returns the csrf token once per session` (m1-04)
  - `SESSION: an owner idle for 31 minutes on the web is 401 token_expired` (m1-04)
  - `SESSION: return_to that is not a same-origin path is 400` (m1-04)
  - `SESSION: a magic link works once and expires after 15 minutes` (m1-04)
  - `ENROLL: authorize with a loopback redirect returns a code and state` (m1-04)
  - `ENROLL: a non-loopback redirect_uri is 400` (m1-04)
  - `ENROLL: PKCE S256 with loopback redirect returns a device id` (m1-04)
  - `ENROLL: a wrong code_verifier is 400` (m1-04)
  - `ENROLL: a redirect_uri different from the authorized one is 400` (m1-04)
  - `ENROLL: a public JWK that is not P-256 is 400` (m1-04)
  - `ENROLL: an enrollment code works once and expires after 10 minutes` (m1-04)
  - `TOKEN: signed nonce returns a 15-minute ES256 token` (m1-04)
  - `TOKEN: a reused nonce is 409 nonce_used` (m1-04)
  - `TOKEN: a revoked device cannot get a token` (m1-04)
  - `TOKEN: a member-audience token authenticates GET /v1/me without a cookie` (m1-04)
  - `TOKEN: a DER-encoded signature is rejected and raw r‖s is accepted` (m1-04)
  - `AUDIT: device.enrolled is written in the same transaction` (m1-04)
  - `AUDIT: no token or secret value appears in audit details` (m1-04)
  - `ROUTINE: a valid routine.json round-trips zod ↔ JSON Schema 2020-12` (m1-05)
  - `ROUTINE: generated routine schemas are fresh` (m1-05)
  - `ROUTINE: unknown fields anywhere are rejected` (m1-05)
  - `ROUTINE: a commit step without capability or connection_ref is rejected` (m1-05)
  - `ROUTINE: a model step with a capability is rejected` (m1-05)
  - `ROUTINE: runs_on device is rejected for read, draft and non-device capabilities` (m1-05)
  - `ROUTINE: foreach must name an earlier step` (m1-05)
  - `ROUTINE: a template with an expression is rejected` (m1-05)
  - `ROUTINE: planCommit returns items with item_hash over JCS and performs no I/O` (m1-05)
  - `ROUTINE: definitionHash changes when a connection_id or tool pin changes` (m1-05)
  - `ROUTINE: describeDefinition names the account and limits for every step` (m1-05)
  - `ROUTINE: checkManifest refuses a capability not in the brief` (m1-05)
  - `ROUTINE: run_budget_usd above 4.00 is rejected` (m1-05)
  - `TRANSFORM: a pure transform maps input to output` (m1-05)
  - `TRANSFORM: fetch, require and timers are not defined inside the isolate` (m1-05)
  - `TRANSFORM: a transform over 1 second is stopped` (m1-05)
  - `TRANSFORM: a transform over 64 MiB is stopped` (m1-05)
  - `FAKE: recorded reads are replayed by capability and args hash` (m1-05)
  - `FAKE: commit items are recorded and never executed` (m1-05)
  - `FAKE: a read with no recording fails the test` (m1-05)

## M2. Hand-fed loop

The critical path. No capture needed.

- **Scope**: manual opportunity (`POST /v1/opportunities`); connections for his first task
  ([OQ-22](OPEN_QUESTIONS.md#oq-22-your-first-hand-fed-task-and-top-admin-drains)) through the launch catalog (his
  internal Google OAuth client, then Composio or a direct API); credential broker with the `aws-kms` or `local` key
  provider; connection pins; fixture capture with tokenisation (C6); brief, check set, held-out check, teeth gate, design
  budget; approvals (one scheme, internal tokens); OK, build with one worker and one retry worker (`fanout_workers = 1`)
  on the Docker provider, then E2B before exit; fresh-sandbox verification; verifier with one repair turn; egress-proxy
  budget with reservations and the $4.00 hard stop; `infra_failed` and the reaper; artifact and signed receipt; deploy
  approval with `definition_hash` shown in words; routine runtime (schedule and manual triggers, `read`, `draft`,
  `transform`, `model` and `commit` steps, ask before commit, item journal, kill switches, basic breakers); TypeScript
  policy rules; audit chain with anchors; a minimal web page for Build progress and batch approval.
- **Exit criteria**: Muhammad types his first task, connects the two apps, sees the fixtures it captured, presses
  OK, build, watches it reach `ready` under $4.00, reads the definition and approves the deploy, and approves the first
  batch on the web page; the items commit through the real connectors exactly once; the audit chain verifies.
- **Acceptance tests**:
  - `DESIGN: reaching $0.60 marks the opportunity needs_you and starts no call`
  - `MANUAL: POST /v1/opportunities stores masked text with source manual and starts no model call`
  - `CONNECT: an option whose app is not connected puts the opportunity in needs_connection`
  - `FIXTURE: fixture capture uses read gate mode only; a commit capability is refused`
  - `FIXTURE: no fixture value reaches a sandbox untokenised (canary)`
  - `PIN: the brief pins connection_id, adapter, tool and pin hash; the runtime never re-resolves`
  - `TEETH: a check that passes on an empty workspace is refused`
  - `TEETH: a check that writes into the workspace is refused`
  - `GATE: OK, build with a wrong check_set_hash is 403 hash_mismatch`
  - `GATE: two concurrent OK, build requests start one build; the other gets 409 already_running`
  - `GATE: a claimed approval cannot be claimed again (approval_used)`
  - `GATE: an approval older than 24 h is 409 approval_expired`
  - `VERDICT: a pass printed inside the worker sandbox does not count; only the fresh verification sandbox decides`
  - `TAMPER: a check file changed during an attempt ends the build as tampered`
  - `PROOF: exit code 0 without a matching nonce proof is not a pass`
  - `FANOUT: a check failure starts exactly fanout_workers more attempts; none sees the held-out check`
  - `REPAIR: a verifier fail sends one repair turn and never fans out`
  - `HELDOUT: a retry build of the same brief gets a new held_out_hash`
  - `CAP: the proxy refuses a call whose worst-case reservation exceeds the remaining cap; the build ends capped`
  - `CAP: three parallel workers cannot together overshoot 4.00 USD`
  - `INFRA: a sandbox provider outage ends infra_failed, bills nothing to the cap and releases the approval once`
  - `REAP: a sandbox tagged for a terminal build is destroyed and audited`
  - `SANDBOX: no credential in env or files; connect to a non-allowlisted host fails`
  - `RECEIPT: receipt signature verifies and covers every hash and cost`
  - `DEPLOY: deploy with a wrong definition_hash is 403; deploy of a build not ready is 409`
  - `DEPLOY: an artifact with a capability outside the brief is refused`
  - `BROKER: a commit whose item hash is not in the approved batch is refused by the broker` (m2-03)
  - `BATCH: approving a batch hash commits only items whose argument hash matches, each once`
  - `JOURNAL: a crash after sending marks the item unknown and it is never re-sent`
  - `JOURNAL: unknown can be released only by a person`
  - `DURABLE: a run waiting for batch approval has no open workflow; approval starts a new one`
  - `POLICY: a commit inside the routine's quiet hours waits and records its rule id`
  - `KILL: a tenant kill switch stops all commits within one run step`
  - `AUDIT: verify detects an edited event, a deleted event and a fork` (m2-12)
  - `VAULT: credential plaintext never appears in logs, events or model prompts` (m2-03)
  - `EGRESS: fetch appears only in allowlisted server modules`
  - Slice tests of [m2-02](../slices/m2-02-connections-catalog/SPEC.md):
    `CONNECTION: POST for a google_internal app returns the broker's authorize_url and stores the connection as needs_reauth`,
    `CONNECTION: the callback activates the connection with the account label and pins its tools`,
    `CONNECTION: an openapi api_key goes to the broker only and never into a row, a log line, an audit event or the response`,
    `CONNECTION: DELETE asks the broker to shred and marks the connection revoked`,
    `CONNECTION: GET /v1/connections never returns external_ref, account_hash or any secret field`,
    `CONNECTION: connections of tenant A are invisible to tenant B`,
    `CONNECTION: no broker call happens inside withTenant`,
    `CATALOG: every app in the ADR 0033 table has exactly one entry with its method and adapter`,
    `CATALOG: every entry validates against CatalogEntry and ships unverified`,
    `CATALOG: availableEntries returns only entries verified in spike S5`,
    `CATALOG: POST for an app that is not available is 400 invalid_request`,
    `PIN: toolPinHash is sha256 of the JCS of name, description and input_schema`,
    `PIN: changing readOnlyHint or any other annotation does not change the pin hash`,
    `PIN: comparePins reports a changed description, a removed tool and a changed adapter as needs_review`,
    `PIN: an existing pin is never overwritten`,
    `PIN: GET /v1/connections/{id}/tools returns the stored pins`,
    `CAPABILITY: GET /v1/capabilities returns every capability with its argument schema and step class`,
    `CAPABILITY: a commit capability without an argument allowlist fails to load`,
    `COMPOSIO: the broker gets the member uuid as user_id, never an email`,
    `COMPOSIO: meta tools are filtered from tool lists and refused as pins`,
    `COMPOSIO: a Composio session names an explicit toolkit and tool allowlist`
  - Slice tests of [m2-03](../slices/m2-03-credential-broker/SPEC.md):
    `KEY: the local provider refuses a master key file readable by group or others`,
    `KEY: the local provider refuses a key file that is not exactly 32 bytes`,
    `KEY: a data key wrapped for tenant A does not unwrap for tenant B`,
    `KEY: aws-kms sends the configured key id and tenant_id as the encryption context`,
    `KEY: a credential row from another key provider fails closed`,
    `VAULT: offload_app cannot select, insert or update credentials or oauth_requests`,
    `VAULT: a ciphertext does not decrypt under another connection's AAD`,
    `VAULT: shred deletes the credential and a later call on that connection fails`,
    `BROKER: the broker hashes the arguments itself and ignores a caller-supplied item hash`,
    `BROKER: a read outside the run's declared read set is refused`,
    `BROKER: gate mode read refuses every commit capability`,
    `BROKER: a request without the service token or with a wrong one is 401 before any lookup`,
    `BROKER: a request to a host outside the provider allowlist is refused and nothing is decrypted`,
    `BROKER: the credential reaches only the upstream auth header and never the caller`,
    `BROKER: the socket file is mode 0600`,
    `OAUTH: begin returns an authorize_url with PKCE S256 and a single-use state`,
    `OAUTH: finish with a used or expired state is refused and stores nothing`,
    `OAUTH: finish exchanges the code with the client secret inside the broker and stores the tokens encrypted`,
    `REFRESH: two concurrent refreshes make one provider call`,
    `REFRESH: an expired lease lets the next caller refresh`,
    `REFRESH: the refresh call runs outside any transaction`,
    `REFRESH: a refused refresh marks the credential failed and the connection needs_reauth`;
    live, skipped without credentials: `LIVE: aws-kms wraps and unwraps a data key with the configured key`
  - Slice tests of [m2-12](../slices/m2-12-audit-anchors/SPEC.md):
    `AUDIT: an untouched chain of 50 events verifies with checked 50`,
    `AUDIT: an empty chain verifies with checked 0`,
    `ANCHOR: writeAnchor signs the JCS of tenant_id, seq, head_hash and signed_at`,
    `ANCHOR: no new anchor is written when the chain head has not moved`,
    `ANCHOR: the hourly job anchors every tenant once per hour in a fake clock`,
    `ANCHOR: the anchor job's workflow input and step outputs hold ids only`,
    `ANCHOR: offload_app cannot update or delete an anchor`,
    `ANCHOR: the signing key never appears in a row or a log line`,
    `VERIFY: an anchor whose head_hash no longer matches its event fails verify`,
    `VERIFY: an anchor with a bad signature fails verify`,
    `VERIFY: GET /v1/audit-events/verify returns ok, checked and first_bad_seq`,
    `VERIFY: a member role gets 403 and an auditor gets the result`,
    `VERIFY: GET /v1/audit-events pages newest first with next_cursor and reads only its own tenant`

Tasks:

| Id | Task | Depends on | Tier | Size | Parallel group | Paths |
|---|---|---|---|---|---|---|
| m2-01 | Manual opportunities and the fix designer options for typed tasks | M1 | Sonnet | M | M2-A | `services/brain/**`, `services/api/**` |
| [m2-02](../slices/m2-02-connections-catalog/SPEC.md) | Connections, launch catalog entries for the first task, connection pins | M1 | Sonnet | M | M2-A | `packages/connectors-sdk/**`, `services/api/src/connections/**` |
| [m2-03](../slices/m2-03-credential-broker/SPEC.md) | Credential broker process and key providers (`aws-kms`, `local`) | M1 | Opus plan, Sonnet build | L | M2-A | `services/broker/**`, migration `0201` |
| m2-04 | Fixture capture with tokenisation and C6 storage | m2-02, m2-03 | Sonnet | M | M2-B | `services/brain/**`, `packages/routine-sdk/**` |
| m2-05 | Brief, check set, held-out check, teeth gate, design budget | m2-01, m2-04 | Opus plan, Sonnet build | L | M2-B | `services/brain/**`, `services/builder/**` |
| m2-06 | Approvals scheme and OK, build endpoint | m2-05 | Sonnet | M | M2-C | `packages/policy/**`, `services/api/**` |
| m2-07 | Build orchestrator: worker, fresh verification, retry worker, verifier and repair turn, receipt | m2-06 | Opus plan, Sonnet build | L | M2-C | `services/builder/**` |
| m2-08 | Model egress proxy with reservations, `infra_failed`, reaper; Docker then E2B provider | m2-06 | Sonnet | L | M2-C | `services/builder/**` |
| m2-09 | Deploy approval with definition in words; routine versions | m2-07 | Sonnet | M | M2-D | `services/runtime/**`, `services/api/**` |
| m2-10 | Runtime: triggers, steps, ask before commit, item journal, breakers, kill switches, TypeScript policy rules | m2-09, m2-03 | Opus plan, Sonnet build | L | M2-D | `services/runtime/**`, `packages/policy/**` |
| m2-11 | Minimal web page: Build progress and batch approval | m2-07, m2-10 | Sonnet | M | M2-D | `apps/web/**` |
| [m2-12](../slices/m2-12-audit-anchors/SPEC.md) | Audit anchors and verify endpoint (runs alone in M2-A: not parallel-safe) | M1 | Sonnet | S | M2-A | `packages/db/src/audit/**`, `services/api/src/audit/**` |

## M3. Capture to cloud

Runs in parallel with M2 after m1-02, m1-03 and m1-04. m3-01 owns `services/api/src/ingest/**` and
`packages/masking/**`; M2 tasks stay out of those folders and rebase before landing (shared-file rule in
[AGENTS.md](../AGENTS.md#slice-format)). Slices:
[m3-01](../slices/m3-01-ingest-batches/SPEC.md), [m3-02](../slices/m3-02-mac-capture-upload/SPEC.md),
[m3-03](../slices/m3-03-mac-signing-sparkle/SPEC.md).

- **Scope**: `POST /v1/ingest/batches` with the full check order, leak scan as a transport check, idempotent insert
  into `observations` and `observation_texts`, outbox event, upload consent (`POST /v1/me/consents`), and the retention
  purge (metadata 30 days, text 7 days);
  Mac observer (Accessibility first, OCR fallback), masker with stable keyed pseudonyms and the pseudonym key in the
  Keychain, encrypted buffer, uploader as egress guard with the local egress ledger; signed and notarized app bundle
  with the locked bundle id (O1 to O3) and Sparkle updates (O11); onboarding permissions with 1.5 s ticks, "Show
  Offload in Finder", and the local "last 10 minutes" line ([ONBOARDING.md](ONBOARDING.md)); recordings import into an
  import space as a backfill, with forget for an import (`POST /v1/me/forget`, scope `import`).
- **Exit criteria**: Muhammad's signed Mac app uploads masked, pseudonymised observations for one full working day to
  his tenant of one; zero leak-scanner hits; the egress ledger shows every batch; the observer has no network code;
  restart mid-upload loses nothing and duplicates nothing; a Sparkle update installs without losing permissions.
- **Acceptance tests**:
  - `INGEST: a valid batch is stored and every id is accepted` (m3-01)
  - `INGEST: same batch twice stores objects once and returns the same receipt` (m3-01)
  - `INGEST: identical resend after restart returns the stored receipt` (m3-01)
  - `INGEST: same seq with different bytes is 409 seq_replay` (m3-01)
  - `INGEST: a seq not above last_seq is 409 seq_replay` (m3-01)
  - `INGEST: sent_at off by 11 minutes is 400 clock_skew and nothing is stored` (m3-01)
  - `INGEST: a bad signature is 401 and nothing is stored` (m3-01)
  - `INGEST: a DER signature or a non-JCS body is rejected` (m3-01)
  - `INGEST: envelope device_id different from the token's device is 403` (m3-01)
  - `INGEST: kind run_outcome is rejected unknown_kind` (m3-01)
  - `INGEST: keyframe envelopes on /batches are 400 unknown_kind` (m3-01)
  - `INGEST: review_event, notice_ack and step_result objects are rejected not_enabled` (m3-01)
  - `INGEST: an object older than 7 days is too_old and one 11 minutes in the future is schema_invalid` (m3-01)
  - `INGEST: 1 MiB + 1 byte is 413 too_large` (m3-01)
  - `INGEST: the 61st request in a minute is 429 rate_limited` (m3-01)
  - `INGEST: an excluded host is rejected excluded` (m3-01)
  - `INGEST: keyframe upload is 403 consent_missing` (m3-01)
  - `INGEST: text snapshots land in observation_texts and other kinds in observations` (m3-01)
  - `LEAK: an email address in text is rejected leak_detected and audited` (m3-01)
  - `LEAK: a card number passing Luhn is rejected` (m3-01)
  - `LEAK: an sk-ant style key is rejected` (m3-01)
  - `LEAK: a URL with a query string in title is rejected` (m3-01)
  - `LEAK: a valid IBAN and a phone number are rejected` (m3-01)
  - `LEAK: pseudonyms and router placeholders pass` (m3-01)
  - `OUTBOX: observations.ingested is written in the same transaction` (m3-01)
  - `TTL: observations older than the raw TTL are dropped by the purge job and logged` (m3-01)
  - `TTL: text snapshots older than the text TTL are dropped while metadata stays` (m3-01)
  - `TTL: changing OFFLOAD_RAW_TTL_DAYS changes what is dropped` (m3-01)
  - `KEYWRAP: a device stores and reads back only its own wrapped key` (m3-01)
  - `KEYWRAP: another device's wrap is 404` (m3-01)
  - `NONET: observer sources contain no networking API` (m3-02, Swift)
  - `NONET: observer target does not link the uploader` (m3-02, Swift)
  - `MASK: card, IBAN, API key and URL query are masked before the day file is written` (m3-02, Swift)
  - `MASK: text over 8000 characters is truncated after masking` (m3-02, Swift)
  - `MASK: unchanged text hash writes no new text_snapshot` (m3-02, Swift)
  - `MASK: Accessibility text is used and OCR runs only under 200 characters` (m3-02, Swift)
  - `MASK: the AX walk stops at 1,500 nodes, depth 12 or 150 ms` (m3-02, Swift)
  - `PSEUDO: the same email on two days gets the same pseudonym` (m3-02, Swift)
  - `PSEUDO: two tenants' keys give different pseudonyms for the same value` (m3-02, Swift)
  - `PSEUDO: a URL keeps its host, its path becomes a doc pseudonym and the query is dropped` (m3-02, Swift)
  - `PSEUDO: a person name in a signature block becomes a person pseudonym` (m3-02, Swift)
  - `PSEUDO: the reveal map resolves a pseudonym on the device and is purged after 7 days` (m3-02, Swift)
  - `EXCLUDE: a password manager window yields the app name only` (m3-02, Swift)
  - `EXCLUDE: a private browsing title marker drops title and host` (m3-02, Swift)
  - `EXCLUDE: a user exclusion added at runtime applies within one 2 s reload` (m3-02, Swift)
  - `STORE: a day file decrypts only with its day key` (m3-02, Swift)
  - `STORE: purge removes days older than 7 and logs them` (m3-02, Swift)
  - `STORE: secure input pauses text capture` (m3-02, Swift)
  - `STORE: screen lock writes pause with reason lock and nothing until resume` (m3-02, Swift)
  - `STORE: a lost Screen Recording grant writes permission_change and AX capture continues` (m3-02, Swift)
  - `UPLOAD: generated Swift types are fresh` (m3-02, Swift)
  - `UPLOAD: JCS matches the shared RFC 8785 vectors` (m3-02, Swift)
  - `UPLOAD: envelope bytes are JCS and the raw r‖s signature verifies with the public JWK` (m3-02, Swift)
  - `UPLOAD: offline queue flushes in seq order after reconnect` (m3-02, Swift)
  - `UPLOAD: kill after send before receipt, restart resends identical bytes and seq` (m3-02, Swift)
  - `UPLOAD: a 409 seq_replay with identical bytes re-reads the receipt and does not lose objects` (m3-02, Swift)
  - `UPLOAD: objects older than 7 days are dropped and counted` (m3-02, Swift)
  - `EGRESS: a request to any host other than the configured API host is refused` (m3-02, Swift)
  - `EGRESS: a detector hit at send time stops the batch and nothing leaves` (m3-02, Swift)
  - `EGRESS: every sent batch appears in the local egress ledger with the exact bytes` (m3-02, Swift)
  - `SPARKLE: an update signed with the EdDSA key installs and keeps Accessibility and Screen Recording grants` (m3-03, manual, CI `mac` job records it)
  - `SIGN: developer-id signing without its secrets prints the names it lacks and exits 0` (m3-03)
  - `SIGN: no packaging script prints a secret value` (m3-03)
  - `SIGN: notarize skips cleanly without the App Store Connect secrets` (m3-03)
  - `SIGN: appcast skips cleanly without the Sparkle private key` (m3-03)
  - `SIGN: signing is inside-out and never uses --deep` (m3-03)
  - `SIGN: every codesign call uses --options runtime --timestamp` (m3-03)
  - `RELEASE: every secret a workflow references is one of the six placeholder names` (m3-03)
  - `RELEASE: no job that runs on pull_request references a secret` (m3-03)
  - `RELEASE: release-mac runs only in the release environment, on a tag or manual dispatch, on macos-26` (m3-03)
  - `RELEASE: the temporary keychain is deleted in a step that always runs` (m3-03)
  - `RELEASE: the secrets check exposes only true or false` (m3-03)
  - `RELEASE: the mac job uploads the bundle before any test step` (m3-03)
  - `RELEASE: promote-mac is manual only and offers promote, halt and rerelease` (m3-03)
  - `BUNDLE: a Mach-O under Resources fails the bundle check` (m3-03)
  - `BUNDLE: an unsigned executable fails the bundle check` (m3-03)
  - `BUNDLE: a missing third-party notices file fails the bundle check` (m3-03)
  - `BUNDLE: a bundle over the size budget fails the bundle check` (m3-03)
  - `BUNDLE: Info.plist has the bundle id, macOS 14.0 minimum, menu bar flag and the four Sparkle keys` (m3-03)
  - `BUNDLE: a dev build gets the .dev bundle id and a missing downloads host leaves the feed keys out` (m3-03)
  - `SPARKLE: the updater flushes the upload queue and stops capture before it installs` (m3-03, Swift)
  - `SPARKLE: beta items are offered only when Get early builds is on` (m3-03, Swift)
  - `SPARKLE: an Info.plist without a signed https feed turns updates off` (m3-03, Swift)
  - `SPARKLE: after an update relaunch both permissions are checked again` (m3-03, Swift)
  - `CONSENT: observations from a member without upload consent are rejected consent_missing` (m3-01)
  - `CONSENT: consent for the current notice version lets the next batch through and is audited` (m3-01)
  - `CONSENT: a stale notice_version is 409 stale_notice and a withdrawn consent blocks uploads again` (m3-01)
  - `CONSENT: GET /v1/me reports upload_consent.needed until consent exists` (m3-01)
  - `IMPORT: forget import wipes every row with that import_id` (m3-05)
  - `IMPORT: an imported object older than 7 days is accepted and its day is the ingest date` (m3-05)
  - `PERF: over a scripted 8-hour day on an M1 Air the observer averages under 3% of one core and stays under 200 MB resident` (m3-04, manual on the owner's Mac, recorded in the PR)
  - `NOW: last-10-minutes line on the Mac fixture is "10 min · Cursor 6m · Chrome 3m · Slack 1m · 14 switches" with zero model calls` (Swift)

Tasks after the two slices:

| Id | Task | Depends on | Tier | Size | Parallel group | Paths |
|---|---|---|---|---|---|---|
| [m3-03](../slices/m3-03-mac-signing-sparkle/SPEC.md) | App bundle, signing, notarization and Sparkle in the CI `mac` job | m3-02; O1 to O3, O11 for the first real release | Sonnet | M | M3-C | `.github/workflows/**`, `apps/mac/Package.swift`, `apps/mac/Packaging/**`, `OffloadMac/Updates/**` |
| m3-04 | Onboarding permissions step, local now line, Never watch | m3-02 | Sonnet | M | M3-C | `apps/mac/**` |
| m3-05 | Recordings import into an import space; imported objects skip `too_old` and use the ingest date as `day` ([ADR 0020](adr/0020-device-ingest-protocol.md)) | m3-02 | Sonnet | M | M3-C | `apps/mac/**`, `services/api/**` |
| m3-06 | Pseudonym key wraps for a second Mac and the recovery code | m3-02 | Opus plan, Sonnet build | M | M3-C | `apps/mac/**`, `services/api/**` |

## M4. Measured saving, loop closed

- **Scope**: hs-1 port (`packages/hours-saved` unchanged in method); a grade C baseline from Muhammad's own estimate
  for the M2 fix, labelled "estimated"; review events from the web page (and the Mac from M5); run savings; fix
  outcomes over 4 weeks as in `outcomes.ts` (PR #45: `on_track` ≥ 0.8, `partial` ≥ 0.5, else `under`;
  `unmeasured` when no week was measured); the monthly flag "Didn't pay off: undo?" for a fix that misses its estimate
  by 50% or more over its first 4 weeks; savings feed ranking confidence. Grade A baselines replace grade C once M3 and
  M5 provide observed instances.
- **Exit criteria**: for Muhammad, the M2 fix shows a weekly saving next to its estimate, labelled honestly, with every
  number opening to its arithmetic. **This closes the first end-to-end loop.**
- **Acceptance tests**:
  - `HS1: the 98 harvested hours-saved tests pass unchanged`
  - `HS1: a user estimate gives a grade C baseline shown as estimated`
  - `HS1: baseline from task-ledger instances → grade A with n ≥ 5 and 2·iqr ≤ median`
  - `HS1: a run with no review event saves 0 with note not_reviewed_yet`
  - `OUTCOME: median saved 80% of the estimate is on_track; 50% is partial; 49% is under`
  - `OUTCOME: a week whose days were purged before measurement is source purged, never guessed`
  - `REALIZED: a fix 50% or more under its estimate over 4 weeks is flagged in the month record and asks "Keep it?"`
  - `FEEDBACK: a fix kind that under-delivers lowers confidence for that kind in the next ranking`
  - `E2E: fixture tenant of one goes manual opportunity → OK, build → deploy → approved batch → measured saving`

| Id | Task | Depends on | Tier | Size | Parallel group | Paths |
|---|---|---|---|---|---|---|
| m4-01 | Port `packages/hours-saved` and its 98 tests | M1 | Sonnet | S | M4-A | `packages/hours-saved/**` |
| m4-02 | Baselines (grade C, then A), review events, run savings | m4-01, M2 | Sonnet | M | M4-A | `services/runtime/**` |
| m4-03 | Fix outcomes, monthly flag, ranking feedback | m4-02 | Sonnet | M | M4-B | `services/brain/**` |

## M5. Observed loop

- **Scope**: sessionize, describe, embed (local), induce; task ledger; episodes; day records nightly; week records;
  profile API and the rest of Mac onboarding (role, goals, drains, rhythm, autonomy, all skippable); model router with
  masking second pass and budgets; Today (day grid, "what you did", repeats with "how it was counted", one suggested
  fix); opportunity finder (score formula, goal alignment, decline penalty, drain boost); instant read; weekly review v1
  (one sentence checked by code, tiles vs usual week, goals, up to 4 questions); pseudonym match on the Mac ("is this
  the sheet?"); observed opportunities enter the M2 build path; Build progress on the Mac; keyframes opt-in.
- **Exit criteria**: after one real week, Muhammad's Today shows one ranked suggested fix from observed work with 2 or
  3 options; he builds it through the same path as M2; the weekly review lands at his review slot; answers change next
  week's ranking; its saving is measured with a grade A baseline.
- **Acceptance tests**:
  - `SPAN: golden event fixture → exact spans (10 s minimum, idle backdated 120 s)`
  - `LEDGER: two fixture weeks of the same work keep ≥ 95% of task keys`
  - `LEDGER: a renamed but same task maps to its old key; a new task gets a new key`
  - `INDUCE: steps sharing a doc pseudonym on different days join the same task`
  - `DAY: golden fixture day → exact DayRecord JSON`
  - `DAY: episode names pass the leak scanner (no emails, names, digits outside the allow-list)`
  - `PROFILE: PATCH with 4 goals is 400; with an 81-char goal is 400; empty profile changes no ranking`
  - `ROUTER: a person name in a prompt reaches the provider as a placeholder (held-out corpus)` (m5-03)
  - `ROUTER: at 100% of the monthly budget paid routes stop with needs_you` (m5-03)
  - `ROUTER: a model returns a label and code maps it to a number` (m5-03)
  - Slice tests of [m5-03](../slices/m5-03-model-router/SPEC.md):
    `ROUTER: a model id outside the allowlist is refused before sending`,
    `ROUTER: a leak scan hit refuses the call and writes privacy.leak_blocked`,
    `ROUTER: untrusted text is wrapped, format characters are stripped and a closing tag cannot escape`,
    `ROUTER: the HTTP backend sends a tool-less Messages request and reads stop_reason first`,
    `ROUTER: each route uses the tier in models.json`,
    `NAMES: placeholder-shaped input becomes name before masking`,
    `NAMES: the same name in one run gets the same placeholder and a new run gets a new tag`,
    `NAMES: the member's own name becomes the me placeholder by default`,
    `NAMES: device pseudonyms pass unchanged`,
    `NAMES: the per-run name map never appears in logs, ledger entries or the result`,
    `BUDGET: a reservation above the run's remaining budget is refused and the provider is not called`,
    `BUDGET: a route whose model has no configured price is refused`,
    `BUDGET: at 80% of the monthly budget classify and caption go to the local tier when it is configured`,
    `BUDGET: every call writes one ledger entry keyed by its call id and settles the reservation`,
    `BUDGET: an escalated call budgets each attempt`,
    `ESCALATE: a refusal from haiku retries on sonnet, then opus`,
    `ESCALATE: a cut-off reply or invalid structured output escalates one tier`,
    `ESCALATE: after opus fails the call ends needs_you and never goes down a tier`,
    `ESCALATE: a model step drops to haiku after 5 clean runs and returns to sonnet on an edit`,
    `LABEL: a schema with a number field is refused before any call`,
    `LABEL: an unknown label throws in mapLabel`,
    `LOCAL: refuses any host that is not loopback or a private network`,
    `LOCAL: the local tier is off when OFFLOAD_LOCAL_MODEL_URL is unset and never serves build`
  - `TODAY: every repeat Figure has arithmetic and evidence`
  - `SCORE: golden factors → exact score for the formula in ARCHITECTURE section 6`
  - `SCORE: empty profile reproduces the fix-rule order`
  - `SCORE: a declined task stays out unless its hours rise ≥ 50% over baseline; not_now returns after 4 weeks`
  - `SCORE: a review answer naming a goal sets alignment to 1`
  - `OPTIONS: leave_alone is first when the best saving is below 0.5 h/week`
  - `INSTANT: an instant read uses read gate mode only and labels every saving estimated`
  - `MATCH: the Mac reports which connector candidate matches a doc pseudonym without uploading the value`
  - `NARRATIVE: a sentence with a number not in the week record is refused`
  - `REVIEW: week record is generated at review_slot in the member's timezone (fake clock)`
  - `REVIEW: GET /v1/review/week for a future week is 404`
  - `KEYFRAME: a keyframe upload without keyframes_to_cloud is 403 consent_missing`

| Id | Task | Depends on | Tier | Size | Parallel group | Paths |
|---|---|---|---|---|---|---|
| [m5-01](../slices/m5-01-understanding/SPEC.md) | Sessionize, describe, embed, induce, task ledger | M3 | Opus plan, Sonnet build | L | M5-A | `services/brain/**` |
| m5-02 | Episodes, day and week records, narrative check | m5-01 | Sonnet | M | M5-A | `services/brain/**` |
| [m5-03](../slices/m5-03-model-router/SPEC.md) | Model router (masking, budgets, escalation, labels) | M1, m3-01 (leak scan) | Sonnet | M | M5-A | `services/brain/src/models/**`, `packages/masking/src/names/**` |
| [m5-04](../slices/m5-04-opportunity-finder/SPEC.md) | Opportunity finder, instant read, options | m5-02, m2-01 | Sonnet | M | M5-B | `services/brain/**` |
| m5-05 | Today and weekly review APIs and Mac screens | m5-04 | Sonnet | L | M5-B | `services/api/**`, `apps/mac/**` |
| m5-06 | Pseudonym match flow and Build progress on the Mac | m5-04, m3-06 | Sonnet | M | M5-B | `apps/mac/**`, `services/api/**` |

## M6. Build and run depth

- **Scope**: fan-out of 3 workers on check failure; the Mac actuator and the device command queue (`script` on the
  device, `browser_automation` attended in his own browser, `setup_change` applied by him); routine repair flow;
  graduation proposals and acceptance; per-routine quiet hours editing; the full circuit breaker list; inbound webhook
  triggers; device step results through ingest.
- **Exit criteria**: a fix that touches a local app runs on his Mac from a typed command after he approves the batch;
  a routine graduates to auto commit after his one-tap OK; a routine whose tool changed is repaired and asks again.
- **Acceptance tests**:
  - `POLICY: browser-automation commits ask even in auto_commit`
  - `FANOUT: with fanout_workers 3, a check failure starts exactly 3 more attempts in parallel`
  - `WINNER: replay and held-out pass beats a smaller diff; among passing attempts the smaller diff wins`
  - `DEVICE: a device command whose item hash is not in the approved batch is refused on the Mac`
  - `DEVICE: an unclaimed command expires after 24 h and its item is failed_before_send`
  - `DEVICE: a claimed command with no result in 10 minutes makes its item unknown`
  - `DEVICE: no actuator command accepts script text`
  - `ACTUATOR: ax.action runs only while the target bundle id is frontmost`
  - `REPAIR: a changed tool pin puts the routine in needs_review; repair yields a new version in ask_before_commit with streak 0`
  - `GRADUATE: 5 clean approved runs propose graduation with an approval_id; an edit resets the streak`
  - `BREAKER: two failed runs in a row pause commits for the routine`
  - `TRIGGER: inbound webhook with a bad signature or skew > 300 s is 401 and starts no run; 300 s is accepted`

| Id | Task | Depends on | Tier | Size | Parallel group | Paths |
|---|---|---|---|---|---|---|
| m6-01 | Fan-out of 3 and the winner rule | M2 | Sonnet | M | M6-A | `services/builder/**` |
| m6-02 | Device command queue and `step_result` ingest | M2, M3 | Sonnet | M | M6-A | `services/runtime/**`, `services/api/**` |
| m6-03 | Mac actuator: `shortcut.run`, `appleevent.template`, `ax.action` | m6-02 | Opus plan, Sonnet build | L | M6-B | `apps/mac/**` |
| m6-04 | `browser.step` after spike S6 | m6-03, S6 | Opus plan, Sonnet build | L | M6-B | `apps/mac/**` |
| m6-05 | Repair flow, graduation, quiet hours editing, breakers, webhook triggers | M2 | Sonnet | L | M6-A | `services/runtime/**`, `services/api/**` |

## M7. User model depth

- **Scope**: entities and entity resolution over pseudonyms, bi-temporal facts, propositions with revise and decay,
  month and quarter records (Theil-Sen trend, persistence, drift), forget (entity, range, all), export,
  confirm-name questions, `GET /v1/facts`.
- **Exit criteria**: Muhammad can ask "since when" questions in the review and get dated answers; forgetting a person
  removes every trace.
- **Acceptance tests**:
  - `FACT: a fact invalidated at T is returned by factsAt(T−1) and not by factsAt(T+1)`
  - `FACT: GET /v1/facts at T returns the fact valid at T with valid_at`
  - `PROP: rate change over 50% creates version 2 and invalidates version 1`
  - `PROP: not seen for 7 analysed days → invalidated, not deleted`
  - `FORGET: forget person X removes aliases, facts, propositions, embeddings and durable workflow rows, and logs to purge_log`
  - `MONTH: golden 4-week fixture → exact month record with Theil-Sen trend`

## M8. Self-host and Pro

- **Scope**: team tenants (`kind = 'team'`: invites, workspaces UI, shared fixes, team review) in `ee/packages/teams`,
  enabled by the Offload Cloud key for Pro (decided 2026-11-14, [OQ-13](OPEN_QUESTIONS.md#oq-13-plan-contents-and-prices); prices open);
  WorkOS AuthKit as the Cloud OIDC issuer; full web app (Today, Weekly review, Build progress, Routines, Settings,
  admin); Offload MCP server (read and propose); outbound webhooks; optional split of `offload serve` into four
  processes; compose and Helm with real templates and the parity suite against compose and Offload Cloud
  ([ADR 0037](adr/0037-hosting-cloud-and-self-host-parity.md)); `container-use` provider; `small_app` hosted by the web app with a
  visual compare-to-brief check; GitHub Actions pinned by commit SHA; public docs; zero data retention (O10) and the
  Composio zero-retention add-on (O9) in place before any second user; privacy policy, terms and DPA
  ([OQ-17](OPEN_QUESTIONS.md#oq-17-privacy-policy-terms-and-dpa)).
- **Exit criteria**: a fresh machine with Postgres and an S3 bucket runs the full loop from the docs with the `local`
  key provider; the same acceptance suite passes against that compose deploy and against Offload Cloud; a 3-person Pro team tenant shares a fix and its review; without the Cloud key, team tenant creation is
  `403 feature_not_licensed`.
- **Acceptance tests**:
  - `SELFHOST: docker compose up + migrations + seed fixture reaches a ready build with the docker provider`
  - `PARITY: the same acceptance suite passes against the compose deploy and the cloud deploy` (one verify suite, run
    twice per release: a deploy verify script added in M8, run against each base URL; the list of parity tests is in
    [ADR 0037](adr/0037-hosting-cloud-and-self-host-parity.md#parity-test-list))
  - `PARITY: the same license key gives the same features[] in GET /v1/me on both deploys`
  - `PARITY: no source file reads a variable that names the hosting mode`
  - `TELEMETRY: a compose deploy with default settings makes no telemetry request`
  - `UPGRADE: a compose deploy of the previous minor upgrades in place and passes the suite`
  - `HELM: helm template with default values renders and passes schema validation`
  - `TEAMS: creating a team tenant without the teams entitlement is 403 feature_not_licensed`
  - `RLS: an admin in a team tenant reads zero C1 and C2 rows of another member`
  - `MCP: offload.propose_opportunity creates an open opportunity with masked text and nothing else`
  - `WEBHOOK: outbound signature verifies with the endpoint secret`
  - `SERVE: offload serve answers /v1/me and ingests a batch`
  - `WEB: every number on Today and Weekly review opens its arithmetic`
  - `CI: every action reference is pinned by a 40-char SHA`

## M9. Enterprise

- **Scope**: license key verification; `@offload-ee/server-ee`; SAML SSO, enforced SSO, SCIM; Cedar custom policies,
  approval chains, policy simulation; SIEM streaming and the external audit anchor sink; configurable retention and
  legal hold; per-person views with compliance records ([OQ-15](OPEN_QUESTIONS.md#oq-15-monitoring-law-features-for-teams));
  BYOC and dedicated deployment guide; continuity: hand-over and offboarding of a departing member's routines (old
  ADR 0107/0113).
- **Exit criteria**: an Enterprise test tenant logs in through SAML, is provisioned by SCIM, runs a routine that needs
  2 of 3 approvers, streams its audit log, and anchors it to an external sink; a departing member's routines are handed
  over; with the key removed, core still works and EE endpoints return `403 feature_not_licensed`.
- **Acceptance tests**:
  - `LICENSE: a key with a bad signature enables no EE feature`
  - `LICENSE: an expired key disables EE features and keeps core running`
  - `SCIM: deprovisioning a user revokes sessions and device tokens and pauses their routines`
  - `CHAIN: a 2-of-3 policy needs two distinct approvers`
  - `CEDAR: a custom policy that denies a capability is enforced with its rule id`
  - `ANCHOR: an anchor written to the external sink re-verifies the chain offline`
  - `CONTINUITY: offboarding a member hands each routine to a named member, paused until they approve`
  - `BOUNDARY: core build has no @offload-ee module in its bundle`
