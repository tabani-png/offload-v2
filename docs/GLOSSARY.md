# Glossary

This is the one vocabulary for Offload v2. Every doc, API, table, test name and UI string uses these words. If a word
is missing, add it here first, in the same commit that uses it.

Conventions:
- Terms are in **bold**. Identifiers are in `code` and match [DATA_MODEL.md](DATA_MODEL.md) and [API.md](API.md).
- "Core" means code outside `ee/`. "EE" means Enterprise code under `ee/`. See [OPEN_CORE.md](OPEN_CORE.md).
- Milestones are M0 to M9 as in [ROADMAP.md](ROADMAP.md).
- Banned words in product copy and APIs: "dry run" and "preview run" (see [ADR 0016](adr/0016-no-dry-run.md)), and the
  marketing words in [PRODUCT.md](PRODUCT.md#copy-rules).

## Product and people

| Term | Meaning |
|---|---|
| **Offload** | The product. A product of consultance.ai. It notices repeated back-office work, builds a fix, deploys it after two approvals and measures the hours it saves. |
| **Owner** (product) | Muhammad Ali Tabani. Makes the decisions listed in [OPEN_QUESTIONS.md](OPEN_QUESTIONS.md). Not to be confused with the `owner` role. |
| **User** | A person who uses Offload. Muhammad is the first user. |
| **Tenant of one** | A personal tenant with exactly one member. The first milestones run Offload for Muhammad as a tenant of one. |
| **Plan** | A commercial tier: **Free** (open core), **Pro** (teams: team tenants, on Offload Cloud or self-host with a key), **Enterprise** (governance, SSO/SCIM, deployment options). The split is decided (single-player core free, multiplayer paid, [OQ-13](OPEN_QUESTIONS.md#oq-13-plan-contents-and-prices), 2026-11-14); prices are not; see [OPEN_CORE.md](OPEN_CORE.md). |
| **Single-player core** | The decided split (OQ-13, 2026-11-14): everything one person needs is core and free; multiplayer (team tenants, invites, workspaces, shared fixes, team review) is paid (EE, enabled for Pro). |
| **Offload Cloud** | Offload hosted by consultance.ai. Same code, images and features as self-host ([ADR 0037](adr/0037-hosting-cloud-and-self-host-parity.md)); it adds operations (upgrades, backups, verified OAuth clients, support). Provider and region: [OQ-01](OPEN_QUESTIONS.md#oq-01-cloud-hosting-provider-and-region). |
| **Self-host** | Offload run by the customer: docker compose on one host, or the Helm chart. Needs Postgres 17 with pgvector and S3-compatible storage. Feature parity with Offload Cloud (decided, [OQ-29](OPEN_QUESTIONS.md#oq-29-hosting-offload-cloud-and-self-host)). |
| **Parity suite** | The acceptance tests that run against a compose deploy and the Offload Cloud deploy and must pass on both before a release is published ([ADR 0037](adr/0037-hosting-cloud-and-self-host-parity.md#parity-test-list)). |
| **Telemetry** | An optional, content-free daily report from a self-host deploy (`OFFLOAD_TELEMETRY`, default `off`). Not the same as Offload Cloud's own observability. |
| **Operator item** | A task only the owner can do outside the code (an account, a certificate, a vendor agreement), with a lead time. Listed in [ROADMAP M0](ROADMAP.md#operator-items). |
| **Spike** | A time-boxed experiment whose result is written into an ADR. Listed in [ROADMAP M0](ROADMAP.md#spikes). |
| **Hand-fed loop** | M2: the build and run half proven on a task the user typed in, before capture feeds opportunities. |

## Clients and services

| Term | Meaning |
|---|---|
| **Mac client** | The thin macOS app (`apps/mac`). Captures, masks and pseudonymises on device, uploads, shows the UI, and runs attended device steps. Holds no brain. |
| **Observer** | The capture part of the Mac client: focus, window titles, idle, Accessibility text, OCR fallback, keyframes. No network code. |
| **Masker** | The on-device masking code. Runs before anything is stored or uploaded. |
| **Egress guard** | The Mac uploader: one destination, closed schemas, detectors again, fail closed ([ADR 0035](adr/0035-mac-egress-guard-and-ledger.md)). |
| **Upload consent** | The member's **Start sending** on onboarding screen 5 ("What leaves your Mac"), recorded in `consents` with the notice version. Nothing is uploaded without a current one; a new notice version asks again. |
| **Local mode** | Signed out, or signed in without upload consent: capture stays in the local 7-day buffer and nothing is uploaded. |
| **Product mode** | What works given sign-in, upload consent, permissions and connections: `Full`, `Watching`, `Text only`, `Screen only`, `Connected apps only`, `Dormant`, `Local` ([ONBOARDING section 10.1](ONBOARDING.md#101-product-modes)). |
| **Egress ledger** | The local 7-day record of every uploaded batch, shown in the app as "What was sent". |
| **Actuator** | The Mac part that runs approved device steps from typed commands only (`OffloadActuator`, [ADR 0025](adr/0025-execution-placement-and-mac-actuator.md)). |
| **Web app** | The React app (`apps/web`). All plans; hosted on Pro and Enterprise. Mirrors the Mac screens and adds admin screens. |
| **Offload serve** | The one process that runs the four modules (`offload serve`) until there is a second tenant ([ADR 0023](adr/0023-service-layout.md)). |
| **API module** | `services/api`. The HTTP edge: public REST, device ingest, device commands, inbound webhooks, auth; the Offload MCP server from M8. |
| **Ingest** | The device upload part of the API module. Accepts signed batches of the closed upload kinds. |
| **Brain** | `services/brain`. Understanding, user model, opportunities, fix designer, model router. Runs in the cloud. |
| **Builder** | `services/builder`. The build orchestrator: checks, approval, workers, verification, verifier, receipts, model egress proxy. |
| **Runtime** | `services/runtime`. The routine runtime: triggers, durable runs, gate, item journal, measurement. |
| **Broker** | `services/broker`. The separate process that alone decrypts and uses connector credentials ([ADR 0034](adr/0034-credential-broker-and-key-providers.md)). |
| **Key provider** | Where the broker's master key lives: `aws-kms`, `gcp-kms`, or `local` (a key file, for self-host). |
| **Service token** | The secret `offload serve` presents on the broker's local socket (`OFFLOAD_BROKER_SERVICE_TOKEN_REF`). The broker refuses any request without it. |
| **Model router** | The one egress for product model calls, in the brain: masking second pass, leak scan, budgets, escalation and usage logging ([ADR 0021](adr/0021-model-router-and-builders.md)). |
| **Route** | A named kind of model call (`design`, `check_write`, `build`, `draft`, `classify`, …) mapped to a tier in `services/brain/config/models.json`. |
| **Escalation** | Retrying a model call one tier up (Haiku, then Sonnet, then Opus) after a refusal, a cut-off or invalid output. Never down. |
| **Label** | A value from a fixed enum that a model returns instead of a number; code maps it to a number ([ADR 0003](adr/0003-numbers-come-from-code.md)). |
| **Durable runtime** | The Postgres-backed durable execution library behind the `DurableRuntime` port ([ADR 0009](adr/0009-durable-execution-on-postgres.md)). Workflows end at every human wait. |

## Tenancy and identity

| Term | Meaning |
|---|---|
| **Tenant** | The top isolation boundary. Every tenant-owned row has `tenant_id`. Enforced by Postgres RLS. |
| **Personal tenant** | A tenant created for one person at sign-up (`tenants.kind = 'personal'`). |
| **Team tenant** | `tenants.kind = 'team'`: invites, several members, shared fixes. Paid, decided in OQ-13 (`ee/packages/teams`). |
| **Workspace** | A group inside a tenant (a team or department). Fixes and routines belong to a workspace. A personal tenant has one workspace. |
| **Member** | A person in a tenant (`members` row). Has one **tenant role** and zero or more workspace memberships. |
| **Member isolation** | The restrictive RLS policy on C1, C2 and C6 tables: a row is visible only to its member, or to an audited aggregate job. |
| **Tenant role** | One of `owner`, `admin`, `member`, `auditor`. Plus the non-human `service` principal. |
| **Workspace role** | One of `lead`, `member` within a workspace. |
| **Principal** | Whoever makes a request: a member session, a device, a service, or a routine acting under a policy. |
| **Device** | One enrolled Mac. Holds a P-256 key in the Secure Enclave where available (else the Keychain, this device only). |
| **Device token** | A 15-minute ES256 JWT minted after a signed challenge. Audience `device` (ingest, device commands) or `member` (the Mac UI calling REST as its member). |
| **Session** | A web login session (cookie `__Host-offload_session`). The Mac UI uses device tokens instead. |
| **Resolver function** | A `SECURITY DEFINER` database function that finds ids before the tenant is known (login, session, device, enrollment code, token). Returns ids only. |

## Capture and privacy

| Term | Meaning |
|---|---|
| **Observation** | One masked event uploaded from the Mac: `focus`, `idle_start`, `idle_end`, `input_counts` (only when turned on in Settings), `text_snapshot`, `pause`, `resume`, `permission_change`. |
| **Accessibility text** | Text read from the focused window by a bounded Accessibility walk. The primary text source; OCR is the fallback under 200 characters. |
| **Observation batch** | A signed, idempotent upload of observations. Upload kind `observation_batch`. |
| **Upload kind** | One of the closed set `observation_batch`, `review_event`, `notice_ack`, `keyframe`, `step_result`. Anything else is rejected `unknown_kind`. |
| **Keyframe** | A masked, downscaled screenshot. Stays on the Mac unless the user turns on `keyframes_to_cloud`. |
| **Exclusion** | An app, host or title marker that is never observed. Built-in plus user-added ("Never watch"). |
| **Never watch** | The person's own exclusions, chosen on onboarding screen 9, in Settings or from the menu bar item. Applied on the Mac before any server call. |
| **Local now summary** | The "last 10 minutes" line on onboarding screen 3: top apps by active minutes and app switches, counted in code on the Mac from the local buffer. No model call, nothing uploaded. |
| **Data class** | `C0` raw on device, `C1` masked observations, `C2` derived user model, `C3` secrets, `C4` governance and account, `C5` build material, `C6` connector content. See [SECURITY_PRIVACY.md](SECURITY_PRIVACY.md#2-data-classes). |
| **Connector content** | Data read from a connected app (C6): fixture reads, instant reads, token maps. 30 days from capture. |
| **Masking** | Destroying sensitive values (secrets, card numbers, IDs, bank numbers, codes) or replacing them with pseudonyms or placeholders before data leaves its boundary. |
| **Pseudonym** | A stable keyed stand-in made on the Mac: `<person:h_…>`, `<email:h_…>`, `<phone:h_…>`, `<doc:h_…>` = first 16 hex of HMAC-SHA256 under the tenant pseudonym key. Equal values give equal pseudonyms ([ADR 0028](adr/0028-stable-keyed-pseudonyms.md)). |
| **Pseudonym key** | 32 random bytes per tenant, held in the Keychain of each enrolled Mac; never stored on the server in the clear. |
| **Reveal** | Showing the real value behind a pseudonym on the Mac only, from the local reveal map (7 days). |
| **Pseudonym match** | The Mac hashes candidate values from a connector and reports which pseudonym each matches ("is this the sheet?"). |
| **Person placeholder** | A per-run placeholder from the model router's second pass for names the device missed: `<person:TAG.N>`, `<person:TAG.N.first>`, `<person:TAG.me>`. `TAG` is a random 4-letter tag per run. |
| **Raw TTL** | How long C1 metadata lives in the cloud. Default 30 days; C1 text snapshots 7 days ([OQ-02](OPEN_QUESTIONS.md#oq-02-raw-ttl-for-masked-observations-in-the-cloud)). |
| **Recordings import** | Optional backfill: read an existing folder of screen recordings (or screenshots, or a screenwatch archive) on the Mac into an **import space**, kept apart from live data and wiped as a unit. |
| **Local insights** | What the recordings import and live capture show, counted in code on the Mac in `.local` backend mode: active time, sessions, focus blocks, switches, top apps and sites (host only) and the things you repeat with minutes per week. Every number is a Figure; no model call, nothing sent (slice m3-10). |
| **Things you repeat** | Local insights' repeats: the same 2 to 4 steps (app, title shape, host) inside one session, on 2 or more days and 3 or more times, with minutes per week, a confidence label and evidence, ranked locally. Their key is the brain's task key shape (`k_` + 12 hex). |
| **Review slot** | When the weekly review lands: a weekday and a local time (default Friday 4:00 PM, from onboarding's rhythm). Before it the Weekly review shows last week's review; at and after it, this week's. Kept on the Mac in `.local`, as the profile's `review_slot` in `.cloud` (slice m3-12). |
| **Your usual** | The comparison on the weekly review's tiles: the median of up to 8 earlier weeks with data. "first week" when there is none (slice m3-12). |
| **Backend mode** | Where the Mac's screens get their data: `.local` (local insights, the default; no API client exists) or `.cloud` (the brain and builds APIs, only with an https API base URL and a member token). |
| **Sample data** | A fixed, labelled example shown only in `.local` backend mode where no real data can exist yet (a build). Always carries the label "Sample data: cloud not connected" and is never mixed with counted numbers. |
| **Sample build** | Build progress's sample data in `.local` backend mode: the mockup's build (8 named workers, one failed check fixed, $0.84 of the $4.00 cap) played once over 92 ticks of 100 ms. Install stays disabled ("Installing needs the cloud."); it is never stored in the builds started on this Mac (slice m3-13). |
| **Builds started on this Mac** | The build ids the Mac keeps (`BuildRecordStore`) because the API has no list route for builds: id, the suggestion's name as shown (a title the brain derived from masked activity), fix id, start time and, after install, the routine id and install time, in this Mac's `UserDefaults`. No hashes, definitions or screen text (slice m3-13). |
| **Interim masker** | `InterimTextMasker`, the recordings import's on-device masker until m3-02's `OffloadMasker.TextMasker` lands: URLs to host plus `<doc:h_…>`, tokens to `[SECRET]`, cards, account numbers and codes to placeholders, emails, phones and person names to pseudonyms under a local pseudonym key. |
| **Import space** | One recordings import: its observations carry `source = "import"` and its `import_id`, never mix with live data, and are wiped together ("Remove imported data", forget scope `import`). |
| **Source purged** | A figure whose raw evidence passed its TTL. It keeps its value and arithmetic and shows the purge date. |
| **Forget** / **Wipe** | Forget deletes a member's data by entity, date range, import or all. Wipe deletes a tenant and destroys its keys. |

## Understanding and the user model

| Term | Meaning |
|---|---|
| **Span** | A continuous focus interval on one app, title and host, idle removed. |
| **Task** | A group of spans with one goal, found by task induction. |
| **Task instance** | One occurrence of a task. |
| **Task key** | A stable id for a task across weeks (`k_` + 12 hex). Kept in the **task ledger**. |
| **Task ledger** | The table that maps each newly induced task to a long-lived task key. |
| **Episode** | One masked record of a focus block or task instance: when, how long, apps, task key, a verb-object name. |
| **Day record** / **Week record** / **Month record** / **Quarter record** | Code-only rollups. Every figure carries its arithmetic and evidence ids. |
| **Figure** | A number with `value`, `unit`, `arithmetic`, `evidence` and `source_purged_at`. Its id is `fig_` + 16 hex. |
| **Entity** | A resolved thing in the user's work: `person`, `organization`, `app`, `project`, `tool`, `goal`, `document`. People and documents are pseudonyms until the user confirms a display name. |
| **Fact** | A bi-temporal edge between entities: `valid_at` / `invalid_at` (when it was true) and `recorded_at` / `expired_at` (when Offload believed it). |
| **Proposition** | A gum-style statement about the user, with confidence (1 to 10), decay and a revision group. Its confidence is computed by rule and never used in ranking arithmetic. |
| **User model** | Profile + entities + facts + propositions + records + task ledger. The long-term, third-person picture of the user. No raw screen data. |
| **Profile** | What the user told Offload: role, industry, goals (up to 3), drains, schedule, review slot, autonomy, exclusions. |
| **Goal** | A 90-day aim from the profile ("ship a product"). Weights ranking. |
| **Drain** | Onboarding answer to "What eats your week?". A ranking prior for weeks 1 to 4 only. |
| **Autonomy** | Profile default for new fixes: `suggest`, `draft`, `run_approved`. |
| **Memory graph port** | The interface the brain uses to store entities and facts. Postgres by default; graphiti adapter optional. |

## Opportunities and fixes

| Term | Meaning |
|---|---|
| **Opportunity** | A repeated piece of work worth fixing. Has a `source`: `finder`, `manual`, `instant_read` or `agent`. |
| **Manual opportunity** | A task the user types in (`POST /v1/opportunities`). Lets the loop start without capture. |
| **Instant read** | A read-only scan of connected apps' last 30 days of metadata that proposes opportunities on day one, with estimated savings. |
| **Opportunity score** | `weeklyHoursSaved × persistence × goalWeight × confidence ÷ max(1, paybackWeeks) × declinePenalty` ([ARCHITECTURE section 6](ARCHITECTURE.md#6-opportunity-finder)). |
| **Fix** | What Offload proposes for an opportunity. Has one **fix kind**. |
| **Fix kind** | Build kinds: `agent_workflow`, `api_integration`, `scheduled_routine`, `script` (a script or macOS Shortcut), `browser_automation`, `small_app`. Non-build outcomes: `setup_change`, `remove_step`, `leave_alone`. |
| **Fix brief** | The spec of a build fix: inputs, outputs, steps with class and `runs_on`, pinned connections, capabilities, acceptance lines, limits, budget. Has a `brief_hash`. |
| **Fix designer** | The brain module that picks fix kinds (code), pins connections, runs fixture capture and writes the brief (Opus words, code numbers). |
| **Needs connection** | Opportunity state while an app the fix needs is not connected. |
| **Fixture capture** | Read-only connector reads of real past instances and their results, done before checks are written ([ADR 0027](adr/0027-fixture-capture-and-connector-content.md)). |
| **Fixture token** | `tok_` + 12 hex: a reversible stand-in for a connector value inside a sandbox. The token map never enters a sandbox. |
| **Design budget** | Spend allowed before OK, build for fixtures, brief and checks. Default $0.60 per opportunity ([OQ-07](OPEN_QUESTIONS.md#oq-07-design-budget-before-ok-build)). |
| **Needs you** | A state or line that asks the user to act: design budget reached, teeth gate failed twice, monthly budget reached. |
| **Suggested fix** | The one opportunity plus its options shown on Today. |
| **Left alone** | Opportunity state `left_alone`, set by the answer `leave_alone` (also a fix kind) or `never`. The task resurfaces only if its hours rise 50% over baseline. "Not now" lasts 4 weeks. |

## Building

| Term | Meaning |
|---|---|
| **OK, build** | The first approval. An exact-hash, single-use **build approval** that starts a build. |
| **Build** | One run of the build orchestrator for one approved brief (`builds` row). |
| **Check set** | The frozen acceptance checks, visible to workers. Hashed (`check_set_hash`). |
| **Held-out check** | An independent check written separately and never shown to workers. Regenerated for every new build of the same brief. |
| **Replay fixtures** | Tokenised recorded reads and expected commit items from fixture capture, replayed against the built routine with a fake connector. |
| **Teeth gate** | Refuses any check (frozen or held-out) that passes on an empty workspace or writes into the workspace. |
| **Worker** | One sandboxed coding agent attempt (`worker_attempts` row). Default one; more only on check failure. |
| **Verification sandbox** | A fresh sandbox built from an attempt's artifact that runs frozen, replay and held-out checks. Its verdict is the only pass that counts. |
| **Fan-out** | Starting more workers after a check failure: 1 in M2, 3 from M6 (`fanout_workers`). |
| **Repair turn** | One extra turn for the same worker after a verifier fail, with the verifier's reasons. |
| **Winner** | The attempt picked by: replay and held-out pass, then smallest diff ([OQ-21](OPEN_QUESTIONS.md#oq-21-drop-mutation-score-from-the-build-winner-rule)). |
| **Verifier** | A separate model call that did not write the code and checks the artifact against the brief's intent. |
| **Tamper hash** | The hash of the check files, re-checked before and after each attempt. A change ends the build as `tampered`. |
| **Nonce proof** | The harness's final line that proves a check really ran and passed. Exit code alone never counts. |
| **Artifact** | The built fix: `routine.json`, pure transform modules and their tests, with `artifact_sha256` ([ADR 0026](adr/0026-routine-artifact-contract.md)). |
| **Routine definition** | The resolved `routine.json` with pinned connections; hashed as `definition_hash` and shown in words before deploy. |
| **Transform** | A pure TypeScript module in an artifact. No I/O; runs in a no-network isolate. |
| **Build receipt** | An Ed25519-signed record of hashes, costs and verdicts for a build. |
| **Build cap** | $4.00 per OK, build. Covers model spend and sandbox time from the OK to ready. |
| **Model egress proxy** | The builder's proxy for worker model calls. Adds the API key, reserves worst-case spend per call and settles actual spend ([ADR 0030](adr/0030-build-budget-at-egress-proxy.md)). |
| **Budget ledger** | Append-only spend records (`budget_entries`) per build, design, run, brain and infra scope. |
| **Infra failed** | Build end state for provider outages, rate limits after retries and proxy failures. Retried, not billed to the cap ([ADR 0031](adr/0031-build-infrastructure-failures.md)). |
| **Reaper** | The job that destroys sandboxes that outlive their build. |
| **Sandbox** | The isolated environment a worker or verification runs in. Providers `e2b`, `docker`, `container-use`, `apple-container` (dev only). |
| **Ready to ship** | A build whose winner passed verification and the verifier. Waits for the deploy approval. |

## Deploying and running

| Term | Meaning |
|---|---|
| **Deploy approval** | The second OK. Exact-hash over `artifact_sha256`, `receipt_hash` and `definition_hash`. Nothing installs without it. |
| **Routine** | A deployed fix that runs on triggers. Has immutable versions. States `active`, `paused`, `needs_review`, `retired`. |
| **Trigger** | `schedule` (cron), `manual`, `webhook` (M6) or `event` (an Offload event). |
| **Run** | One execution of a routine. |
| **Step class** | `read`, `draft`, `commit`, `transform` or `model`. Only `commit` changes something outside Offload. |
| **Runs on** | Where a step executes: `cloud` or `device` ([ADR 0025](adr/0025-execution-placement-and-mac-actuator.md)). |
| **Device command** | An approved device step queued for the Mac (`device_commands`). The result comes back as upload kind `step_result`. |
| **Awaiting device** | Run state while device commands wait for the Mac. |
| **Capability** | A verb a connector offers, from a fixed vocabulary such as `mail.send`, `sheet.append`, `calendar.events`. |
| **Connection pin** | The `connection_id`, adapter, tool name and tool pin hash fixed in the brief. The runtime never re-resolves ([ADR 0033](adr/0033-pinned-connector-resolution-and-launch-catalog.md)). |
| **Item** | One unit of work in a run (one email, one row). |
| **Item journal** | Per-item states `pending → sending → sent | failed_before_send | unknown`, written before the call. `unknown` is never retried automatically; a person may release it. |
| **Batch** | The set of commit items in a run, identified by `batch_hash` (sha256 of JCS). |
| **Gate mode** | `read` (reads only, used by fixture capture and instant read) or `live` (reads and gated commits). |
| **Commit mode** | `ask_before_commit` (default after deploy) or `auto_commit` (after graduation). |
| **Graduation** | A policy decision that moves a routine from `ask_before_commit` to `auto_commit`. |
| **Repair** | Rebuilding a routine from the same brief plus failure evidence; the new version asks before commit again. |
| **Quiet hours** | A per-routine limit, default 01:00 to 03:59 member-local, during which commits wait. |
| **Circuit breaker** | A rule that pauses a routine's commits (for example 2 failed runs in a row). |
| **Kill switch** | Stops all commits at tenant, workspace, member or routine scope. |
| **Connector** | How Offload reaches a tool: an MCP server, a Composio toolkit, a direct API (OpenAPI), or browser automation. Chosen and pinned at design time. |
| **Launch catalog** | The method per app at launch (for example Google apps through the owner's internal OAuth client) ([ADR 0033](adr/0033-pinned-connector-resolution-and-launch-catalog.md)). |
| **Credential vault** | Per-tenant envelope-encrypted store for connector credentials, read only by the broker. |

## Measuring

| Term | Meaning |
|---|---|
| **hs-1** | The measured-hours-saved method ([ADR 0022](adr/0022-hours-saved-hs-1.md)). Integer seconds, code only. |
| **Baseline** | Median active seconds per item of the task before the fix: grade A/B from recorded instances, grade C from the user's estimate. |
| **Residual** | Review + edit + fix seconds the user still spends on a run. |
| **Measured** / **Estimated** | Grade A/B baselines are "measured"; grade C (user estimate) is "estimated". Estimates from the fix designer are always labelled "estimated". |
| **Fix outcome** | Measured vs estimated over the 4 weeks after a fix ships: `pending`, `on_track` (≥ 80%), `partial` (≥ 50%), `under`, `unmeasured`. |
| **Realized** | Sum of measured hours saved by shipped fixes, shown next to the sum of their estimates. |

## Governance

| Term | Meaning |
|---|---|
| **Gate** | The code path every external action passes. Nothing commits without an approval or a policy allow. |
| **Approval** | A single-use, exact-hash approval with an internal token hashed at rest and a TTL of 24 h. Kinds: `build`, `deploy`, `batch`, `graduation`. |
| **Policy engine** | `packages/policy`: hand-written TypeScript rules behind the `PolicyEngine` port in core; Cedar custom policies in EE (M9). |
| **Policy decision** | `allow`, `ask` or `deny`, with the id of the rule that decided. |
| **Audit event** | An append-only, per-tenant hash-chained record: `hash = sha256(prev_hash || JCS(event_without_hash))`, with `prev_hash` as 64-char hex text. |
| **Audit anchor** | A signed checkpoint of a tenant's chain head. Stored in the same database unless an EE external anchor sink is set. |
| **License key** | An Ed25519-signed key that entitles EE features (`OFFLOAD_EE_LICENSE_KEY`). |

## Copy words

| Term | Meaning |
|---|---|
| **Today** | The Mac/web home screen: the day grid, repeats, one suggested fix. |
| **Weekly review** | One sentence, a few tiles against your usual week, goals, up to 4 one-tap questions whose answers tune next week's ranking. Charts one tap deeper. On the Mac it is counted from local insights in `.local` and read from the brain in `.cloud` (slice m3-12). |
| **Build progress** | The screen that shows checks running, failures being fixed, spend against the cap, and the install step. |


| **Day grid** | Today's 15-minute cells from the person's rhythm start to end (widened to whole hours for activity outside), one row per top app on the Mac (kinds of work in the cloud, from m5-05's `GET /v1/today`), plus a **Switch bursts** row marking cells with 4 or more app switches. |
| **Menu bar line** | The menu bar item's one line about today, "today · 3 h 10 m · mostly Xcode", shown only when something was counted today. |
| **Weekly review** | One sentence, a few tiles, goals, quick questions. Charts one tap deeper. |
| **Build progress** | The screen that shows checks running, failures being fixed, spend against the cap, and the install step. On the Mac (slice m3-13): five step rows (Plan locked, Checks frozen first, Workers testing, Matches what you asked for, Ready to ship), one row per worker attempt with its frozen and held-out marks, the OK, build plan step and the deploy approval. |
| **"How it was counted"** | The drill-down behind every number: arithmetic and evidence. |
| **"What was sent"** | The screen that shows the local egress ledger. |
