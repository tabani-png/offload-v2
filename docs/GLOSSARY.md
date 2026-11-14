# Glossary

This is the one vocabulary for Offload v2. Every doc, API, table, test name and UI string uses these words. If a word
is missing, add it here first, in the same commit that uses it.

Conventions:
- Terms are in **bold**. Identifiers are in `code` and match [DATA_MODEL.md](DATA_MODEL.md) and [API.md](API.md).
- "Core" means code outside `ee/`. "EE" means Enterprise code under `ee/`. See [OPEN_CORE.md](OPEN_CORE.md).
- Banned words in product copy and APIs: "dry run" (see [ADR 0016](adr/0016-no-dry-run.md)), and the marketing words in
  [PRODUCT.md](PRODUCT.md#copy-rules).

## Product and people

| Term | Meaning |
|---|---|
| **Offload** | The product. A product of consultance.ai. It notices repeated back-office work, builds a fix, deploys it after two approvals and measures the hours it saves. |
| **Owner** (product) | Muhammad Ali Tabani. Makes the decisions listed in [OPEN_QUESTIONS.md](OPEN_QUESTIONS.md). Not to be confused with the `owner` role. |
| **User** | A person who uses Offload. Muhammad is the first user. |
| **Tenant of one** | A personal tenant with exactly one member. The first milestones run Offload for Muhammad as a tenant of one. |
| **Plan** | A commercial tier: **Free** (open core, self-host or personal), **Pro** (hosted, small teams), **Enterprise** (governance, SSO/SCIM, deployment options). See [OPEN_CORE.md](OPEN_CORE.md). |

## Clients and services

| Term | Meaning |
|---|---|
| **Mac client** | The thin macOS app (`apps/mac`). Captures, masks on device, uploads, shows the UI. Holds no brain. |
| **Observer** | The capture part of the Mac client: focus, window titles, idle, input counts, text on change, keyframes. No network code. |
| **Masker** | The on-device masking code. Runs before anything is stored or uploaded. |
| **Web app** | The React app (`apps/web`) for Pro and Enterprise. Mirrors the Mac screens and adds admin screens. |
| **API service** | `services/api`. The HTTP edge: public REST, device ingest, the Offload MCP server, inbound webhooks, auth. |
| **Ingest** | The device upload module inside the API service. Accepts signed observation batches. |
| **Brain** | `services/brain`. Understanding, user model, opportunity finder, fix designer. Runs in the cloud. |
| **Builder** | `services/builder`. The build orchestrator: checks, approval, workers, verifier, receipts. |
| **Runtime** | `services/runtime`. The routine runtime: triggers, durable runs, item journal, commits, measurement. |
| **Durable runtime** | The Postgres-backed durable execution library used by the builder and runtime ([ADR 0009](adr/0009-durable-execution-on-postgres.md)). |

## Tenancy and identity

| Term | Meaning |
|---|---|
| **Tenant** | The top isolation boundary. Every tenant-owned row has `tenant_id`. Enforced by Postgres RLS. |
| **Personal tenant** | A tenant created for one person at sign-up (`tenants.kind = 'personal'`). |
| **Workspace** | A group inside a tenant (a team or department). Fixes and routines belong to a workspace. A personal tenant has one workspace. |
| **Member** | A person in a tenant (`members` row). Has one **tenant role** and zero or more workspace memberships. |
| **Tenant role** | One of `owner`, `admin`, `member`, `auditor`. Plus the non-human `service` principal. |
| **Workspace role** | One of `lead`, `member` within a workspace. |
| **Principal** | Whoever makes a request: a member session, a device, a service, or a routine acting under a policy. |
| **Device** | One enrolled Mac. Holds a P-256 key in the Keychain. |
| **Device token** | A 15-minute ES256 JWT minted for a device after a signed challenge. Audience `device`. |
| **Session** | A web or Mac UI login session (cookie `__Host-offload_session`). |

## Capture and privacy

| Term | Meaning |
|---|---|
| **Observation** | One masked event uploaded from the Mac: `focus`, `idle_start`, `idle_end`, `input_counts`, `text_snapshot`, `pause`, `resume`. |
| **Observation batch** | A signed, idempotent upload of observations. Upload kind `observation_batch`. |
| **Upload kind** | One of the closed set `observation_batch`, `review_event`, `notice_ack`, `keyframe`. Anything else is rejected. |
| **Keyframe** | A masked, downscaled screenshot. Stays on the Mac unless the user turns on `keyframes_to_cloud`. |
| **Exclusion** | An app, host or title marker that is never observed. Built-in plus user-added ("Never watch"). |
| **Data class** | `C0` raw on device, `C1` masked observations, `C2` derived user model, `C3` secrets, `C4` governance records, `C5` build artifacts. See [SECURITY_PRIVACY.md](SECURITY_PRIVACY.md#2-data-classes). |
| **Masking** | Replacing sensitive values (secrets, card numbers, emails, person names and so on) with placeholders before data leaves its boundary. |
| **Person placeholder** | `<person:TAG.N>`, `<person:TAG.N.first>`, `<person:TAG.me>`. `TAG` is a random 4-letter tag per run. |
| **Raw TTL** | How long `C1` observations live in the cloud. Default 30 days ([OQ-02](OPEN_QUESTIONS.md#oq-02-raw-ttl-for-masked-observations-in-the-cloud)). |
| **Recordings import** | Optional seed: read an existing folder of screen recordings into an **import space**, kept apart from live data. |

## Understanding and the user model

| Term | Meaning |
|---|---|
| **Span** | A continuous focus interval on one app, title and host, idle removed. |
| **Task** | A group of spans with one goal, found by task induction. |
| **Task instance** | One occurrence of a task. Recorded instances become replay fixtures. |
| **Task key** | A stable id for a task across weeks (`k_` + 12 hex). Kept in the **task ledger**. |
| **Task ledger** | The table that maps each newly induced task to a long-lived task key. |
| **Episode** | One masked record of a focus block or task instance: when, how long, apps, task key, a verb-object name. |
| **Day record** / **Week record** / **Month record** / **Quarter record** | Code-only rollups. Every figure carries its arithmetic and evidence ids. |
| **Entity** | A resolved thing in the user's work: `person`, `organization`, `app`, `project`, `tool`, `goal`. People are stored as salted-hash ids until the user confirms a display name. |
| **Fact** | A bi-temporal edge between entities: `valid_at` / `invalid_at` (when it was true) and `recorded_at` / `expired_at` (when Offload believed it). |
| **Proposition** | A gum-style statement about the user, with confidence (1 to 10), decay and a revision group. Words only, never a number used in arithmetic. |
| **User model** | Profile + entities + facts + propositions + records + task ledger. The long-term, third-person picture of the user. No raw screen data. |
| **Profile** | What the user told Offload: role, industry, goals (up to 3), drains, schedule, review slot, autonomy, exclusions. |
| **Goal** | A 90-day aim from the profile ("ship a product"). Weights ranking. |
| **Drain** | Onboarding answer to "What eats your week?". A ranking prior for weeks 1 to 4 only. |
| **Autonomy** | Profile default for new fixes: `suggest`, `draft`, `run_approved`. |
| **Memory graph port** | The interface the brain uses to store entities and facts. Postgres by default; graphiti adapter optional. |

## Opportunities and fixes

| Term | Meaning |
|---|---|
| **Opportunity** | A repeated piece of work worth fixing, ranked by the deterministic score in [ARCHITECTURE section 6](ARCHITECTURE.md#6-opportunity-finder). |
| **Opportunity score** | `weeklyHoursSaved × persistence × goalWeight × confidence ÷ max(1, paybackWeeks) × declinePenalty`. |
| **Fix** | What Offload proposes for an opportunity. Has one **fix kind**. |
| **Fix kind** | Build kinds: `agent_workflow`, `api_integration`, `scheduled_routine`, `script`, `browser_automation`, `small_app`. Non-build outcomes: `setup_change`, `remove_step`, `leave_alone`. |
| **Fix brief** | The spec of a build fix: inputs, outputs, capabilities, step classes, acceptance lines, budget. Has a `brief_hash`. |
| **Fix designer** | The brain module that picks fix kinds (code) and writes the brief (Opus words, code numbers). |
| **Suggested fix** | The one opportunity plus its options shown on Today. |
| **Left alone** | A user's "leave it alone" or "never". The task resurfaces only if its hours rise 50% over baseline. |

## Building

| Term | Meaning |
|---|---|
| **OK, build** | The first approval. An exact-hash, single-use **build approval** that starts a build. |
| **Build** | One run of the build orchestrator for one approved brief (`builds` row). |
| **Check set** | The frozen acceptance checks, visible to workers. Hashed (`check_set_hash`). |
| **Held-out check** | An independent check written separately and never shown to workers. Hashed. |
| **Replay fixtures** | Masked recordings of the user's real task instances, replayed against the built fix inside the sandbox. |
| **Teeth gate** | Refuses any check (frozen or held-out) that passes on an empty workspace or writes into the workspace. |
| **Worker** | One sandboxed coding agent attempt (`worker_attempts` row). Default one; more only on failure. |
| **Fan-out** | Starting 3 more workers after the first worker fails. |
| **Winner** | The attempt picked by: held-out pass, then mutation score, then smallest diff. |
| **Verifier** | A separate agent that did not write the code and checks the result against the brief's intent. |
| **Tamper hash** | The hash of the check files, re-checked before and after each attempt. A change ends the build as `tampered`. |
| **Nonce proof** | The harness's final line that proves a check really ran and passed. Exit code alone never counts. |
| **Artifact** | The built fix: files plus manifest, stored in object storage, with `artifact_sha256`. |
| **Build receipt** | An Ed25519-signed record of hashes, costs and verdicts for a build. |
| **Build cap** | $4.00 per OK, build. Covers all model spend from the OK to ready. |
| **Budget ledger** | Append-only spend records per build, per routine and per tenant. |
| **Sandbox** | The isolated environment a worker runs in. Cloud: E2B microVM. Self-host/dev: container-use on Dagger, or Docker. |
| **Ready to ship** | A build whose winner passed frozen, held-out and replay checks and the verifier. Waits for the deploy approval. |

## Deploying and running

| Term | Meaning |
|---|---|
| **Deploy approval** | The second OK. Exact-hash over the artifact and the receipt. Nothing installs without it. |
| **Routine** | A deployed fix that runs on triggers. Has immutable versions. |
| **Trigger** | `schedule` (cron), `webhook`, or `event` (an Offload event). |
| **Run** | One execution of a routine. |
| **Step class** | `read`, `draft` or `commit`. Only `commit` changes something outside Offload. |
| **Capability** | A verb a connector offers, from a fixed vocabulary such as `mail.send`, `sheet.append`, `calendar.events`. |
| **Item** | One unit of work in a run (one email, one row). |
| **Item journal** | Per-item states `pending → sending → sent | failed_before_send | unknown`, written before the call. `unknown` is never retried automatically. |
| **Batch** | The set of commit items in a run, identified by `batch_hash` (sha256 of JCS). |
| **Commit mode** | `ask_before_commit` (default after deploy) or `auto_commit` (after graduation). |
| **Graduation** | A policy decision that moves a routine from `ask_before_commit` to `auto_commit`. |
| **Circuit breaker** | A rule that pauses a routine's commits (for example 2 failed runs in a row). |
| **Kill switch** | Stops all commits at tenant, workspace, member or routine scope. |
| **Connector** | How Offload reaches a tool: an MCP server, a Composio toolkit, a direct API (OpenAPI), or browser automation, in that order. |
| **Credential vault** | Per-tenant envelope-encrypted store for connector credentials. |

## Measuring

| Term | Meaning |
|---|---|
| **hs-1** | The measured-hours-saved method ([ADR 0022](adr/0022-hours-saved-hs-1.md)). Integer seconds, code only. |
| **Baseline** | Median active seconds per item of the task before the fix, from recorded instances. |
| **Residual** | Review + edit + fix seconds the user still spends on a run. |
| **Measured** / **Estimated** | Grade A/B baselines are "measured"; grade C (user estimate) is "estimated". Estimates from the fix designer are always labelled "estimated". |
| **Realized** | Sum of measured hours saved by shipped fixes, shown next to the sum of their estimates. |

## Governance

| Term | Meaning |
|---|---|
| **Gate** | The code path every external action passes. Nothing commits without an approval or a policy allow. |
| **Approval** | A single-use, exact-hash, hashed-at-rest token with a TTL. Kinds: `build`, `deploy`, `batch`, `graduation`. |
| **Policy** | A Cedar policy evaluated by the policy engine. Core ships fixed built-in policies; EE adds custom ones. |
| **Policy decision** | `allow`, `ask` or `deny`, with the id of the rule that decided. |
| **Audit event** | An append-only, per-tenant hash-chained record: `hash = sha256(prev_hash || JCS(event))`. |
| **Audit anchor** | A signed checkpoint of a tenant's chain head. |
| **License key** | An Ed25519-signed key that entitles EE features (`OFFLOAD_EE_LICENSE_KEY`). |

## Copy words

| Term | Meaning |
|---|---|
| **Today** | The Mac/web home screen: the day grid, repeats, one suggested fix. |
| **Weekly review** | One sentence, a few tiles, goals, quick questions. Charts one tap deeper. |
| **Build progress** | The screen that shows checks running, failures being fixed, spend against the cap, and the install step. |
| **"How it was counted"** | The drill-down behind every number: arithmetic and evidence. |
