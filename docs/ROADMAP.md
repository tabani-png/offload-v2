# Roadmap

Milestones in order. Each has scope, exit criteria and named acceptance tests. A milestone is done when every
acceptance test exists, ran red first, and now passes in `scripts/verify-all.sh` (or the CI `mac` job for Swift), and
the owner has seen the exit demo. Words follow [GLOSSARY.md](GLOSSARY.md).

M1 to M6 take **Muhammad, as a tenant of one**, from capture to a measured saving end to end. Later milestones widen it.

Test naming: `TAG: sentence` inside the package's `tests/<slice-id>/` folder, as in [AGENTS.md](../AGENTS.md#slice-format).

## M0. Harness and architecture (this commit)

- **Scope**: docs, ADRs, monorepo skeleton, CI stub, harness scripts, slice template, first M1 slice specs.
- **Exit criteria**: `scripts/verify-all.sh` green on the Linux box; every doc link resolves; core never imports `ee/`.
- **Acceptance tests** (exist now):
  - `scripts/tests/license-boundary.test.ts`: passes clean core; fails on static import, relative path, dynamic import, manifest dependency.
  - `scripts/tests/doc-links.test.ts`: GitHub-style slugs; fails on a missing target.
  - one `tests/smoke.test.ts` per workspace package.

## M1. Capture to cloud

Slices: [m1-01](../slices/m1-01-contracts-ingest/SPEC.md), [m1-02](../slices/m1-02-tenancy-rls/SPEC.md),
[m1-03](../slices/m1-03-device-enrollment/SPEC.md), [m1-04](../slices/m1-04-ingest-batches/SPEC.md),
[m1-05](../slices/m1-05-mac-capture-upload/SPEC.md).

- **Scope**: ingest contracts; Postgres tenancy with forced RLS and the durable-runtime spike; personal tenant on
  first login; device enrollment and tokens; `POST /v1/ingest/batches`; Mac observer, masker, encrypted buffer and
  uploader; raw-TTL purge job.
- **Exit criteria**: Muhammad's Mac uploads masked observations for one full working day to a cloud tenant of one;
  zero leak-scanner hits on that day; observer has no network code; restart mid-upload loses nothing and duplicates
  nothing.
- **Acceptance tests**:
  - `CONTRACT: observation_batch round-trips zod ↔ JSON Schema 2020-12` (m1-01)
  - `CONTRACT: JCS canonical bytes match RFC 8785 vectors` (m1-01)
  - `RLS: every tenant table has FORCE ROW LEVEL SECURITY` (m1-02)
  - `RLS: offload_app with tenant A reads zero rows of tenant B` (m1-02)
  - `DURABLE: a two-step workflow killed between steps resumes once on Bun` (m1-02)
  - `ENROLL: PKCE S256 with loopback redirect returns a device id` (m1-03)
  - `TOKEN: signed nonce returns a 15-minute ES256 token; a reused nonce is 409` (m1-03)
  - `INGEST: same batch twice stores objects once and returns the same receipt` (m1-04)
  - `INGEST: replayed seq is 409 seq_replay; sent_at off by 11 minutes is rejected` (m1-04)
  - `INGEST: an email address in text is rejected leak_detected and audited` (m1-04)
  - `INGEST: kind run_outcome is rejected unknown_kind` (m1-04)
  - `NONET: observer sources contain no networking API` (m1-05, Swift)
  - `MASK: card, IBAN, API key, email and URL query are masked before the day file is written` (m1-05, Swift)
  - `UPLOAD: offline queue flushes in seq order after reconnect` (m1-05, Swift)
  - `TTL: observations older than the raw TTL are dropped by the purge job and logged` (m1-04)

## M2. Understanding, records and Today

- **Scope**: sessionize, describe, embed (local), induce; task ledger; episodes; day records nightly; week records;
  profile API and Mac onboarding (permissions ticking every 1.5 s, local "last 10 minutes" line with pointer, role,
  goals, drains, rhythm and boundaries, recordings import, hands-on, all skippable); model router with masking and
  budget; Today screen with day grid, "what you did" and repeats with "how it was counted".
- **Exit criteria**: after one real day, Muhammad's Today shows a day grid and at least one repeat whose numbers open
  to their arithmetic; no model wrote a number; profile answers stored and editable.
- **Acceptance tests**:
  - `SESSION: golden event fixture → exact spans (10 s minimum, idle backdated 120 s)`
  - `LEDGER: two fixture weeks of the same work keep ≥ 95% of task keys`
  - `LEDGER: a renamed but same task maps to its old key; a new task gets a new key`
  - `DAY: golden fixture day → exact DayRecord JSON`
  - `DAY: episode names pass the leak scanner (no emails, names, digits outside the allow-list)`
  - `PROFILE: PATCH with 4 goals is 400; with an 81-char goal is 400; empty profile changes no ranking`
  - `ROUTER: a person name in a prompt reaches the provider as a placeholder (held-out corpus)`
  - `ROUTER: at 100% of the monthly budget paid routes stop with needs_you`
  - `NOW: last-10-minutes line on the Mac fixture is "10 min · Cursor 6m · Chrome 3m · Slack 1m · 14 switches" with zero model calls` (Swift)
  - `TODAY: every repeat Figure has arithmetic and evidence`

## M3. One opportunity

- **Scope**: opportunity finder (score formula, goal alignment, decline penalty, drain boost); fix designer options
  (kinds, saving, confidence, effort in code; Opus wording); Today suggested fix (1 / 2 / 3, recommended, leave it
  alone); weekly review v1 (one sentence checked by code, tiles vs usual week, goals, up to 4 questions).
- **Exit criteria**: Muhammad's Today shows one ranked suggested fix with 2 or 3 options; the weekly review lands at
  his review slot; answers change next week's ranking.
- **Acceptance tests**:
  - `SCORE: golden factors → exact score for the formula in ARCHITECTURE section 6`
  - `SCORE: empty profile reproduces the fix-rule order`
  - `SCORE: a declined task stays out unless its hours rise ≥ 50% over baseline`
  - `SCORE: a review answer naming a goal sets alignment to 1`
  - `OPTIONS: leave_alone is first when the best saving is below 0.5 h/week`
  - `NARRATIVE: a sentence with a number not in the week record is refused`
  - `REVIEW: GET /v1/review/week for a future week is 404`

## M4. OK, build

- **Scope**: brief, check set, held-out check, replay fixtures, teeth gate, design budget; approvals (one scheme);
  `POST /v1/fixes/{id}/build-approvals`; build orchestrator with one worker, fan-out of 3 on failure, winner rule,
  verifier, artifact, signed receipt, budget ledger with $4.00 hard stop; E2B sandbox provider and Docker provider for
  dev; Build progress screen on the Mac.
- **Exit criteria**: Muhammad presses OK, build on a simple fix (a `script` or `scheduled_routine` from his real
  opportunities); it reaches `ready` under $4.00 with frozen, held-out and replay checks passing; the screen shows
  checks running, spend against the cap, and a separate install step.
- **Acceptance tests**:
  - `TEETH: a check that passes on an empty workspace is refused`
  - `TEETH: a check that writes into the workspace is refused`
  - `GATE: OK, build with a wrong check_set_hash is 403 hash_mismatch`
  - `GATE: the same approval claimed twice concurrently starts one build; the other gets 409 approval_used`
  - `GATE: an approval older than 24 h is 409 approval_expired`
  - `TAMPER: a check file changed during an attempt ends the build as tampered`
  - `PROOF: exit code 0 without a matching nonce proof is not a pass`
  - `FANOUT: first attempt fails held-out → exactly 3 more attempts start; none sees the held-out check`
  - `WINNER: held-out pass beats mutation score; mutation score beats smaller diff`
  - `CAP: spend reaching 4.00 USD ends the build as capped and starts no new call`
  - `SANDBOX: no credential in env or files; connect to a non-allowlisted host fails`
  - `RECEIPT: receipt signature verifies and covers every hash and cost`

## M5. Deploy and run, asking before commit

- **Scope**: deploy approval; routines and versions; triggers (schedule, webhook); runtime on the durable runtime;
  connectors (MCP client first, Composio adapter, OpenAPI client); credential vault; gate with exact-hash batch
  approvals; item journal; ask before commit; circuit breakers; kill switches; built-in Cedar policies; audit chain and
  anchors.
- **Exit criteria**: the M4 fix is deployed with a second OK, runs on its trigger, prepares a batch, Muhammad approves
  it from the Mac, items commit through a real connector, and the audit chain verifies.
- **Acceptance tests**:
  - `DEPLOY: deploy with a wrong artifact_sha256 is 403; deploy of a build not ready is 409`
  - `BATCH: approving a batch hash commits only items whose argument hash matches, each once`
  - `JOURNAL: a crash after sending marks the item unknown and it is never re-sent`
  - `JOURNAL: unknown can be released only by a person`
  - `POLICY: a commit between 01:00 and 03:59 local is denied with its rule id`
  - `POLICY: browser-automation commits ask even in auto_commit`
  - `BREAKER: two failed runs in a row pause commits for the routine`
  - `KILL: a tenant kill switch stops all commits within one run step`
  - `AUDIT: verify detects an edited event, a deleted event and a fork`
  - `VAULT: credential plaintext never appears in logs, events or model prompts`

## M6. Measured saving, end to end

- **Scope**: hs-1 port (`packages/hours-saved` unchanged in method); baselines from the task ledger; review events from
  the Mac and web; run savings; week record realized vs estimated; weekly review complete ("Keep it?" after 4 weeks
  under half the estimate); saving flows back into ranking confidence.
- **Exit criteria**: for Muhammad, one deployed fix shows a measured weekly saving in the weekly review, next to its
  estimate, with every number opening to its arithmetic. **This closes the first end-to-end loop.**
- **Acceptance tests**:
  - `HS1: the 98 harvested hours-saved tests pass unchanged`
  - `HS1: baseline from task-ledger instances → grade A with n ≥ 5 and 2·iqr ≤ median`
  - `HS1: a run with no review event saves 0 with note not_reviewed_yet`
  - `REALIZED: 4 weeks below 50% of the estimate raises the keep-or-undo question`
  - `FEEDBACK: a fix kind that under-delivers lowers confidence for that kind in the next ranking`
  - `E2E: fixture tenant of one goes observe → opportunity → OK, build → deploy → approved batch → measured saving`

## M7. User model depth

- **Scope**: entities and entity resolution, bi-temporal facts, propositions with revise and decay, month and quarter
  records (Theil-Sen trend, persistence, drift), forget (entity, range, import, all), export, confirm-name questions,
  graduation proposals.
- **Exit criteria**: Muhammad can ask "since when" questions in the review and get dated answers; forgetting a person
  removes every trace; a routine graduates to auto commit after his one-tap OK.
- **Acceptance tests**:
  - `FACT: a fact invalidated at T is returned by factsAt(T−1) and not by factsAt(T+1)`
  - `PROP: rate change over 50% creates version 2 and invalidates version 1`
  - `PROP: not seen for 7 analysed days → invalidated, not deleted`
  - `FORGET: forget person X removes aliases, facts, propositions and embeddings and logs to purge_log`
  - `MONTH: golden 4-week fixture → exact month record with Theil-Sen trend`
  - `GRADUATE: 5 clean approved runs propose graduation; an edit resets the streak`

## M8. Self-host and Pro

- **Scope**: web app (Today, Weekly review, Build progress, Routines, Settings, admin); workspaces and invites;
  Offload MCP server; outbound webhooks; `offload serve --all`; compose and Helm with real templates; container-use
  sandbox provider; GitHub Actions pinned by commit SHA; signed and notarized Mac build; public docs.
- **Exit criteria**: a fresh machine with Postgres and an S3 bucket runs the full loop from the docs; a 3-person Pro
  workspace shares a fix and its review.
- **Acceptance tests**:
  - `SELFHOST: docker compose up + migrations + seed fixture reaches a ready build with the docker provider`
  - `MCP: offload.propose_opportunity creates an open opportunity and nothing else`
  - `WEBHOOK: outbound signature verifies; a 5-minute-old timestamp is rejected inbound`
  - `WEB: every number on Today and Weekly review opens its arithmetic`
  - `CI: every action reference is pinned by a 40-char SHA`

## M9. Enterprise

- **Scope**: license key verification; `@offload-ee/server-ee`; SAML SSO, enforced SSO, SCIM; custom Cedar policies,
  approval chains, policy simulation; audit export and SIEM streaming; configurable retention and legal hold;
  per-person views with compliance records; BYOC and dedicated deployment guide.
- **Exit criteria**: an Enterprise test tenant logs in through SAML, is provisioned by SCIM, runs a routine that needs
  2 of 3 approvers, and exports its audit log; with the key removed, core still works and EE endpoints return
  `403 feature_not_licensed`.
- **Acceptance tests**:
  - `LICENSE: a key with a bad signature enables no EE feature`
  - `LICENSE: an expired key disables EE features and keeps core running`
  - `SCIM: deprovisioning a user revokes sessions and device tokens and pauses their routines`
  - `CHAIN: a 2-of-3 policy needs two distinct approvers`
  - `EXPORT: exported audit JSONL re-verifies offline`
  - `BOUNDARY: core build has no @offload-ee module in its bundle`
