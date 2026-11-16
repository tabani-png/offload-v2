# Security and privacy

This is an engineering document, not legal advice. Compliance notes say what the design supports; a lawyer must
confirm what any customer or jurisdiction requires. Words follow [GLOSSARY.md](GLOSSARY.md).

## 1. Stance

- Collect metadata first; read text from the Accessibility tree, OCR only as a fallback; mask and pseudonymise on the
  device before anything is stored or sent ([ADR 0006](adr/0006-metadata-first-capture.md),
  [ADR 0005](adr/0005-masked-text-only-reaches-models.md), [ADR 0028](adr/0028-stable-keyed-pseudonyms.md)).
- Say plainly what leaves. **Text from the screen is uploaded**, masked and pseudonymised. Pixels are not, unless the
  user opts in to masked keyframes.
- Keep raw data short-lived and derived data honest about where it came from.
- One egress point on the Mac, a short list of egress modules on the server
  ([ADR 0035](adr/0035-mac-egress-guard-and-ledger.md)).
- Every external action passes a gate ([ADR 0004](adr/0004-every-external-action-is-gated.md)). Credentials are used
  only by the credential broker ([ADR 0034](adr/0034-credential-broker-and-key-providers.md)).
- Build untrusted code only in sandboxes that hold no secrets and no real user values
  ([ADR 0011](adr/0011-sandboxed-build-workers.md), [ADR 0027](adr/0027-fixture-capture-and-connector-content.md)).
- Separate the lanes: a model that reads untrusted content has no tools ([section 7](#7-prompt-injection-defenses)).
- Safety features are core. Trust is not an upgrade.

## 2. Data classes

| Class | Examples | Lives | Leaves its boundary? | Retention |
|---|---|---|---|---|
| **C0** raw on device | screen frames, unmasked text, unmasked titles and URLs, the pseudonym reveal map, the local egress ledger | Mac encrypted store | **Never** | 7 days |
| **C1** masked observations | focus events, masked and pseudonymised titles, URL host plus `<doc:h_…>` path pseudonym, idle, permission changes, masked text snapshots, masked keyframes (opt-in) | Mac buffer, then cloud `observations`, `observation_texts`, `keyframes` | Mac → Offload cloud only | Metadata 30 days (`R-raw`); text snapshots 7 days (`R-text`) ([OQ-02](OPEN_QUESTIONS.md#oq-02-raw-ttl-for-masked-observations-in-the-cloud)) |
| **C2** derived user model | episodes, records, task ledger, entities (pseudonyms until confirmed), facts, propositions, profile, goals | Cloud | Masked text to model providers | Until forgotten ([OQ-03](OPEN_QUESTIONS.md#oq-03-keep-the-derived-user-model-long-term)) |
| **C3** secrets | connector credentials, OAuth tokens, BYOK model keys, webhook secrets, the master key or KMS grant | Credential broker only | Only into the outbound request it authorises | Until disconnected; crypto-shredded on tenant delete |
| **C4** governance and account | audit events, approvals, receipts, budget ledger, purge log; account data such as member email | Cloud | EE export or SIEM if configured | 6 years team, 1 year personal (`R-gov`); account data for the life of the tenant, departed members' personal data 90 days after they leave |
| **C5** build material | briefs, checks, held-out checks, tokenised fixtures, artifacts | Object storage, sandboxes | To the sandbox provider during a build, tokenised only | Routine retired + 90 days, or build failed + 30 days (`R-artifact`) |
| **C6** connector content | fixture reads (his real rows, mails, records), expected commit items, fixture token maps, instant-read metadata, pseudonym match candidates | Cloud (`fixture_token_maps`, `instant_reads`, fixture objects), encrypted by the broker key | Never into a sandbox in clear: values are tokenised per fixture set. Candidate values go to the user's own Mac for pseudonym matching | 30 days from capture (`R-content`); a rebuild after that re-runs fixture capture |

C6 is real content. It exists because replay fixtures need real instances
([ADR 0027](adr/0027-fixture-capture-and-connector-content.md)). It is read only in gate mode `read`, never written by
a model, and never kept longer than its TTL.

## 3. What leaves the Mac

That masked screen text goes to the cloud is the owner's decision of 2026-11-14 ("Yes, masked text can go to the
cloud", [OQ-28](OPEN_QUESTIONS.md#oq-28-masked-screen-text-to-the-cloud)). Pixels stay on the Mac by default; masked
keyframes are opt-in. On a self-host deploy, "the cloud" is the self-hoster's own server.

All of it goes through the uploader, which is the Mac egress guard: one destination (the configured API host), closed
schemas with `additionalProperties: false`, the detectors run again, and it fails closed
([ADR 0035](adr/0035-mac-egress-guard-and-ledger.md)). Every uploaded batch is written to a local 7-day **egress
ledger** that the user can read in the app ("What was sent"): exactly what left, bytes and counts.

By default:
- masked observations (`observation_batch`): app bundle id and name, masked and pseudonymised window title, URL **host**
  plus a path pseudonym (`<doc:h_…>`; query and fragment dropped), idle transitions, pause and resume with reason,
  permission changes, and **masked text snapshots of what is on screen** (≤ 8000 chars, from the Accessibility tree or
  OCR). People, email addresses, phone numbers and document ids appear only as stable keyed pseudonyms
  (`<person:h_…>`, `<email:h_…>`, `<phone:h_…>`, `<doc:h_…>`) ([ADR 0028](adr/0028-stable-keyed-pseudonyms.md));
- review timings (`review_event`), notice acknowledgements (`notice_ack`), and results of device-run steps
  (`step_result`, M6) ([ADR 0025](adr/0025-execution-placement-and-mac-actuator.md));
- the user's answers (profile, review answers, approvals signed by the device key, pseudonym matches) through the REST
  API.

Per-minute key and click **counts** are off by default; Input Monitoring is not requested at setup.

Only with `keyframes_to_cloud` on ([OQ-04](OPEN_QUESTIONS.md#oq-04-keyframes-to-the-cloud)): masked keyframes (masked
lines and secure fields blacked out, 1280 px, JPEG q 0.6).

Never: frames when keyframes are off, unmasked text, which keys were pressed, URL queries or fragments, real names or
addresses behind pseudonyms, anything from excluded apps, hosts or private windows beyond the app name, the pseudonym
key, the Keychain master key or the device private key.

The local "last 10 minutes" onboarding line is computed on the Mac and sends nothing. Nothing is uploaded before
upload consent: **Start sending** on onboarding screen 5 records it (`POST /v1/me/consents`, table `consents`), and
ingest rejects observations `consent_missing` without it.

Retention of what is sent (defaults pending [OQ-02](OPEN_QUESTIONS.md#oq-02-raw-ttl-for-masked-observations-in-the-cloud),
read from `OFFLOAD_TEXT_TTL_DAYS` and `OFFLOAD_RAW_TTL_DAYS`): screen text 7 days, app and window details 30 days;
the derived user model is kept until deleted (default pending
[OQ-03](OPEN_QUESTIONS.md#oq-03-keep-the-derived-user-model-long-term)).

[ONBOARDING.md screen 5](ONBOARDING.md#screen-5-what-leaves-your-mac) says this section in plain words: the same items
and the same retention numbers. If one changes, the other changes in the same commit.

## 4. Threat model

Assets: C1 to C6 data; the ability to commit actions as the user; build sandboxes; the audit chain; license keys.

| Threat | Example | Mitigation |
|---|---|---|
| Cross-tenant read | Bug in a query returns another tenant's rows | RLS forced on every tenant table and partition; app role has no BYPASSRLS; tenant id only from verified tokens; RLS coverage test |
| Cross-member read in a team tenant | An admin's query bug shows a colleague's screen-derived data | Restrictive `member_isolation` policy on every C1, C2 and C6 table (`member_id = app.member_id`, or `app.member_scope = 'tenant'` set only by audited aggregate jobs) ([ADR 0013](adr/0013-tenancy-and-rls.md)). It protects against query bugs, not against malicious server code |
| Stolen device token | Malware on the Mac replays uploads | 15-minute tokens, P-256 key in the Secure Enclave where available (else Keychain, this device only), signed bodies, `seq` and ±10 min window, device revoke |
| Stolen session | Web cookie theft | `__Host-` cookie, httpOnly, Secure, SameSite=Lax, CSRF token, idle timeouts, server-side revocation. The Mac UI uses the device key, not a cookie ([ADR 0014](adr/0014-identity.md)) |
| Unmasked data upload | Masker misses a secret | Mac egress guard re-runs detectors and fails closed; server transport scan; reject and audit `privacy.leak_blocked`; held-out masking corpora in CI |
| Re-identification from pseudonyms | Someone with the cloud data guesses an email and checks its pseudonym | Pseudonyms are keyed HMACs; the key never leaves the user's Macs in clear ([ADR 0028](adr/0028-stable-keyed-pseudonyms.md)) |
| Model provider exposure | Provider logs prompts | Masked, pseudonymised text only; per-run placeholders for leftover names; images only by opt-in; provider terms per [OQ-05](OPEN_QUESTIONS.md#oq-05-model-provider-terms-and-monthly-model-budget) |
| Prompt injection | A web page or email tells a model to send money | Lane separation and the gate, see [section 7](#7-prompt-injection-defenses) |
| Unapproved commit | Bug or injection triggers a send | Gate with exact-hash approvals, item journal, default-deny policy, broker re-check of gate token and item hash, kill switches |
| Duplicate commit | Crash between send and journal | Journal `sending` before the call; `unknown` never retried automatically |
| Device command tampering | A compromised path alters a device step | The Mac re-checks the item hash against the approved item before running; typed commands only, none takes script text ([ADR 0025](adr/0025-execution-placement-and-mac-actuator.md)) |
| Credential misuse inside Offload | A model step or bug reads a token | Only the broker process can decrypt; models and sandboxes never see credentials ([ADR 0034](adr/0034-credential-broker-and-key-providers.md)) |
| Sandbox escape or exfiltration | Worker code reads secrets or calls out | One sandbox per attempt, no secrets, tokenised fixtures, no network except the model egress proxy, see [section 8](#8-sandbox-threats) |
| Fake pass | Worker prints the proof line itself | The only pass that counts is a re-run in a fresh verification sandbox ([ADR 0029](adr/0029-build-verdicts.md)) |
| Check tampering | Worker edits the acceptance check | Read-only mount, tamper hash before and after, harness nonce proof, held-out check never visible |
| Weak checks | Check passes on an empty workspace | Teeth gate, held-out check (regenerated per build), replay fixtures |
| Overspend | Parallel workers overshoot the cap | Reservations at the model egress proxy, per-worker pre-allocation ([ADR 0030](adr/0030-build-budget-at-egress-proxy.md)) |
| Audit tampering | Admin deletes events | Append-only triggers, hash chain with unique prev hash, verify endpoint. Anchors in the same database do not prove anything against the operator; EE external anchor sink does ([ADR 0018](adr/0018-audit-log-hash-chain.md)) |
| Durable state leak | Step inputs hold content outside RLS | Durable schema holds ids only; purged on forget and wipe ([ADR 0009](adr/0009-durable-execution-on-postgres.md)) |
| License bypass | EE feature used without a key | Offline Ed25519 key check at startup and use; the real control is the license terms; core is useful without EE |
| Insider at Offload | Support staff reads user data | Support access only through time-boxed, audited grants (max 72 h) approved by the tenant owner |
| Supply chain | Malicious dependency | Exact pins, lockfile in CI (`--frozen-lockfile`), new dependency needs a SPEC line or ADR, actions pinned by SHA before public release, prebuilt sandbox images |
| Self-host build host takeover | A build worker reaches the host's Docker socket | The `docker` provider talks only to a separate sandbox daemon (compose profile `builds`, or a separate host), never the host socket; the same `SandboxProvider` contract tests and egress allowlist as E2B ([ADR 0037](adr/0037-hosting-cloud-and-self-host-parity.md)) |
| Secrets in the public repo | A key lands in a commit and the repo is public ([OQ-27](OPEN_QUESTIONS.md#oq-27-publish-the-repository-publicly)) | Names only in `.env.example`, secrets hygiene check in CI, a full-history secret scan before the first push ([DEPLOYMENT section 6.5](DEPLOYMENT.md#65-before-the-public-push)), rotation at once after any exposure |
| Fork pull request on a self-hosted runner | Code from a fork runs on a persistent Mac | No self-hosted runner for `pull_request` jobs on the public repo ([OQ-25](OPEN_QUESTIONS.md#oq-25-ci-capacity-for-macos)) |

## 5. Masking

- **On device** (Swift Masker, harvested from the old engine detectors):
  - destructive masking for structured secrets: card numbers (Luhn), CVV and expiry, SSN, SIN, bank routing and
    account, IBAN, CUSIP, ISIN, OTP codes, API keys and tokens, private keys and seed phrases, URL user info, query and
    fragment;
  - **stable keyed pseudonyms** for join keys: person names, email addresses, phone numbers and URL paths or document
    ids become `HMAC-SHA256(tenant pseudonym key, normalised value)`, first 16 hex, shaped `<person:h_…>`,
    `<email:h_…>`, `<phone:h_…>`, `<doc:h_…>`. Equality survives across days and devices; the value does not leave
    ([ADR 0028](adr/0028-stable-keyed-pseudonyms.md));
  - excluded windows yield the app name only; secure input pauses text capture.
- **Device-side reveal**: the Mac keeps a 7-day reveal map (C0). The UI shows the real name next to a pseudonym only on
  the device. To link a pseudonym to a connector object ("is this the sheet?"), the server sends candidate values (C6)
  to the Mac UI, which hashes them and posts matches (`POST /v1/pseudonyms/matches`).
- **Server side** (`packages/masking`):
  - a **transport check**, not an independent second pass. In M3 it runs these rules on every ingest object: email
    address, Luhn-valid card number, IBAN, API-key patterns (section 9 list), URL with a path or query, phone number.
    Names are not scanned server-side in M3. It catches a broken or old client; it fails where the device rules fail;
  - the model router's person-name masker on every model request, with per-run placeholders `<person:TAG.N>`,
    `<person:TAG.N.first>`, `<person:TAG.me>` for names the device missed; placeholder-shaped input becomes `<name>`.
- An **on-device model pass** (PR #42 A§6.3) is evaluated in M3: adopt it if it raises name and address recall by at
  least 3 points at under 50 ms per 1,000 characters on an M1 Air. The rules stay the floor.
- People in the user model are pseudonyms until the user confirms a name in the review ("Is this person Dana?", shown
  with the real name on the Mac only).
- Measured in CI: held-out masking corpora (names, secrets) with a maximum miss rate set in the masking slice; a miss
  above it fails the build.

## 6. Encryption and keys

| Where | How |
|---|---|
| Mac store | AES-256-GCM per day key, wrapped by a 32-byte master key in the login Keychain (this device only, after first unlock). Same-user processes on the Mac can still read the Keychain item with user consent; this is the documented trust boundary of the Mac |
| Mac app settings | The onboarding state (setup position, answers to the six questions, the person's Never watch list and typed text, re-ask dates) is a plain property list in the app's `UserDefaults`, readable by same-user processes and included in backups. It holds no screen content, keys or tokens. It moves into the sealed Mac store when that store lands (m3-02); until then the Never watch list is the most sensitive item in it |
| Pseudonym key | 32 random bytes per tenant, generated on the first enrolled Mac, in the Keychain. A second Mac gets it wrapped to its P-256 key (ECDH P-256, HKDF-SHA256, AES-256-GCM) by a Mac that has it, or from the recovery code shown once at first enrollment (scrypt). Never stored server-side in the clear ([ADR 0028](adr/0028-stable-keyed-pseudonyms.md)) |
| Device identity | P-256 private key in the Secure Enclave where available (non-exportable), else the Keychain, this device only; public JWK registered at enrollment. Signatures are raw `r‖s` (64 bytes), base64url without padding |
| In transit | TLS 1.2+ (prefer 1.3), HSTS |
| Postgres | Provider encryption at rest (KMS); PITR backups encrypted |
| Credentials and C6 | Envelope encryption by the credential broker: per-tenant data key (AES-256-GCM) wrapped by a `KeyProvider`: `aws-kms` (Cloud default, `OFFLOAD_KMS_KEY_REF`), `gcp-kms`, or `local` (32-byte master key in `OFFLOAD_MASTER_KEY_FILE`, readable only by the broker's OS user) for self-host with only Postgres. Encryption context = `tenant_id`. Rotation re-wraps data keys; tenant delete destroys the data key (crypto-shred) ([ADR 0034](adr/0034-credential-broker-and-key-providers.md)) |
| Object storage | SSE-KMS (or the local provider's key); per-object keys under the tenant prefix |
| Signing | Ed25519 service keys for build receipts and audit anchors (`OFFLOAD_SERVICE_SIGNING_KEY_REF`; KMS-held or HSM in EE dedicated); device tokens signed with `OFFLOAD_DEVICE_TOKEN_SIGNING_KEY_REF`; license keys verified with public keys compiled into `packages/license` |
| Approvals | 32 random bytes, only `sha256` stored, single use, TTL 24 h, internal to the server (never shown to a client) |

## 7. Prompt-injection defenses

Untrusted sources: screen text, connector reads and tool results, emails, web pages, webhook bodies, MCP tool
descriptions, text from manual or agent-proposed opportunities.

- **Lane separation**: a model that reads untrusted content has no tools. Routine `model` steps are tool-less and return
  structured output only; all I/O is done by the runtime through the broker
  ([ADR 0026](adr/0026-routine-artifact-contract.md)). The one stated exception is the **build worker**: it has file
  and shell tools inside its sandbox and reads the brief and tokenised fixtures. It has no network except the model
  egress proxy, no credentials and no real values, and its output counts only after code re-runs the checks in a fresh
  sandbox.
- Untrusted content is wrapped in one tag, `<untrusted source="...">…</untrusted>` (for example
  `source="screen"`, `source="tool_output"`, `source="webhook"`), with Unicode format characters stripped, and the
  system prompt states that instructions inside it are data.
- **Models never hold authority**: they cannot open the gate, choose recipients outside the run's input set, or change
  policy. Commits need an exact-hash approval or a policy allow computed in code. Model labels map to numbers in code.
- Capability and argument allowlists: a commit's arguments must match the capability schema; recipients outside the
  run's input set are refused with `422 recipient_not_allowed`.
- Connector resolution is pinned at design time; a changed tool definition (pin hash) pauses the routine in
  `needs_review` ([ADR 0033](adr/0033-pinned-connector-resolution-and-launch-catalog.md)).
- Read steps are enforced read-only by capability class, and the broker checks each read against the run's declared
  read set.
- Browser-automation commits always ask, run on the user's Mac and are attended.
- Manual and agent-proposed opportunity text is masked and leak-scanned before storage
  ([ADR 0036](adr/0036-opportunity-sources-and-instant-read.md)).
- The Offload MCP server (M8) exposes read and propose only.

## 8. Sandbox threats

**Lesson from old ADR 0013 (same-uid `KERN_PROCARGS2`)**: on macOS, code running under the same user inside
`sandbox-exec` could read the full argv **and environment** of every other process of that uid through
`sysctl KERN_PROCARGS2`, which the sandbox does not mediate. On macOS 26.5.1 (2026-10-26) a same-user `bun` returned
61 environment entries of another process. Any token exported in a terminal, an editor plugin or another agent session
was exposed. `/bin/ps` being setuid root also exposed other users' argv. Conclusion: **never run untrusted build code
as a user who has secrets in other processes**, and never rely on a policy sandbox for secret isolation.

v2 design ([ADR 0011](adr/0011-sandboxed-build-workers.md)):
- Builds never run on the user's Mac. Each attempt gets its own microVM (E2B) or container. The `apple-container`
  provider is for development only, on a dedicated build Mac that holds no user secrets.
- No secrets inside: the model key is added by an egress proxy outside the sandbox; connector credentials never enter.
- **No real user values inside**: fixtures are tokenised per fixture set (`tok_` + 12 hex); the token map stays in
  Postgres, encrypted by the broker key ([ADR 0027](adr/0027-fixture-capture-and-connector-content.md)).
- Network deny by default. Sandboxes start from **prebuilt images with a pinned dependency set and no package-registry
  access**: fixtures hold user data, so nothing may be fetched while they are present.
- Checks read-only and hashed; harness nonce proof. **The only pass that counts** is frozen + replay + held-out re-run
  in a fresh verification sandbox from the attempt's artifact; in-worker `run_checks` is advisory
  ([ADR 0029](adr/0029-build-verdicts.md)).
- Artifacts are scanned for known secret patterns and for calls outside the brief's declared capabilities before
  "Ready to ship". Transform modules are pure and run in a no-network isolate at run time.
- Resource caps (2 vCPU, 4 GiB, 12 min per worker, 5 min per verification sandbox) and the $4.00 budget, enforced by
  reservations at the egress proxy, bound abuse ([ADR 0030](adr/0030-build-budget-at-egress-proxy.md)). A reaper
  destroys orphaned sandboxes every 5 minutes ([ADR 0031](adr/0031-build-infrastructure-failures.md)).
- Deployed routines do not run in a build sandbox. The runtime interprets `routine.json`; I/O happens only through the
  broker. Most routines need no run sandbox at all.

## 9. Secrets

- No secret values in code, logs, env files in git, model prompts, sandbox images, durable workflow state or audit
  events.
- `.env.example` lists names only; `scripts/check-secrets-hygiene.sh` fails if another env file exists or a value is set.
- Log scrubbing redacts known secret patterns (sk-ant, sk-, gh*_, github_pat_, AKIA/ASIA, xox*, JWT, PEM, Bearer/Basic,
  `KEY=value`), including base64 and URL-encoded forms. The same API-key patterns feed the server transport scan.
- Credentials are references where the platform allows (Composio connected account, OAuth grant).
- Only the broker decrypts. It re-checks the gate token and item hash before a commit and the run's declared read set
  before a read. Token refresh is single-flight with a lease: a short transaction takes the lease, the refresh call runs
  outside any transaction, a second short transaction writes the result. **No network I/O inside `withTenant`.**
- Server egress is limited by lint and test: `fetch`, `Bun.connect`, `node:http(s)` and `node:net` may appear only in
  the model router, the broker, the sandbox provider, the model egress proxy, the OIDC client and outbound webhooks
  ([ADR 0035](adr/0035-mac-egress-guard-and-ledger.md)).

## 10. Sub-processors

Planned for Offload Cloud (owner confirms in [OQ-01](OPEN_QUESTIONS.md#oq-01-cloud-hosting-provider-and-region) and
[OQ-17](OPEN_QUESTIONS.md#oq-17-privacy-policy-terms-and-dpa)):

| Sub-processor | Purpose | Data | Notes |
|---|---|---|---|
| Cloud host (default AWS, `ca-central-1`) | Compute, Postgres, object storage, KMS | C1 to C6 | |
| Anthropic | Model inference | Masked, pseudonymised text (C1, C2 and tokenised C6 excerpts), masked images only if opted in | Standard retention for the tenant of one; zero data retention is an operator item before any second user. Product routes use Opus, Sonnet and Haiku only: per PR #42, Fable and Mythos models are excluded from Anthropic ZDR |
| E2B | Build sandboxes | Briefs, checks, tokenised fixtures (C5) | No real values, no credentials |
| Google (the owner's own OAuth client, internal to his Workspace) | Connector auth for Gmail, Calendar, Sheets, Drive | Tokens held by the broker; reads and commits he approved | Tenant of one only ([ADR 0033](adr/0033-pinned-connector-resolution-and-launch-catalog.md)) |
| Composio (only for tenants or apps that connect through it) | Tool auth and execution | Tool arguments, results and credentials for that tool | Default payload logging keeps tool arguments and results for up to a year; a zero-retention add-on exists and must be enabled before any second user. Offload uses an opaque `user_id`, an explicit toolkit and tool allowlist, never exposes meta tools, REST only |
| WorkOS (from M8, Pro) | Login, SSO, directory | Member email, name, IdP attributes | Not used in M1 to M7 |

Self-hosters choose their own; the core ships with no mandatory third party except the model provider they configure.
A self-host deploy sends nothing to consultance.ai: license keys are verified offline and telemetry is off unless the
self-hoster turns it on (`OFFLOAD_TELEMETRY=on`: a daily content-free report, [ADR 0037](adr/0037-hosting-cloud-and-self-host-parity.md#telemetry)).
The Mac app's Sparkle update check goes to Offload's download host and carries no user data.

## 11. Retention, export, forget, wipe

- The retention job (`retentionPurge`, run as `offload_retention`) drops `observations` partitions past
  `OFFLOAD_RAW_TTL_DAYS` (30), `observation_texts` partitions past `OFFLOAD_TEXT_TTL_DAYS` (7), C6 rows and objects past
  `OFFLOAD_CONTENT_TTL_DAYS` (30), and deletes `keyframes` rows past the raw TTL **and their objects**. It logs every run
  to `purge_log`.
- Figures whose evidence is gone keep their numbers and arithmetic and show `source_purged` with the date.
- **Export**: `GET /v1/me/export` returns all of a member's C2 data and settings as JSON.
- **Forget**: entity (cascade to aliases, facts, propositions, embeddings), date range (observations, texts, episodes,
  day records in range; week records recomputed), import space, or all. Durable workflow state is ids only and is
  purged too.
- **Wipe**: delete the tenant; data keys destroyed; backups expire with the point-in-time recovery window (7 days, [DEPLOYMENT section 7](DEPLOYMENT.md#7-cloud-deploy-for-the-tenant-of-one)).
- **Pause learning**: stops ingest processing; the Mac stops uploading.
- Every action writes `purge_log` and an audit event.

## 12. Compliance notes (not legal advice)

- **Personal use** (tenant of one): Canada PIPEDA and Ontario; Quebec Law 25 if users in Quebec; GDPR for EU users.
  Design supports access, export, correction (profile and confirm-name), deletion, purpose limitation, regional hosting.
- **Teams (monitoring laws)**, carried from old ADR 0108: per-person views and working-time features are off by
  default and need an owner enablement record with jurisdictions, legal basis, DPIA attestation, notice version and
  notice period (default 14 days; minimum 1 for NY, DE, CT); works agreement for Germany; Quebec activation
  acknowledgement; Delaware daily notice; New York acknowledgement at hire. Features not enabled for a jurisdiction are
  hidden. Group aggregates have a floor of 5 people with complementary suppression. No ranking of people. Self-view
  shows who viewed my data. Which of these ship in which plan is [OQ-15](OPEN_QUESTIONS.md#oq-15-monitoring-law-features-for-teams).
- **Model providers**: Anthropic API standard data retention applies unless the tenant uses BYOK under its own terms.
  Zero data retention needs a vendor agreement (operator item before any second user) and excludes some models.
- **Composio**: default execution logs hold payloads for up to a year; disclose this to any user who connects through
  it until the zero-retention add-on is on.
- **SOC 2 / ISO 27001**: not in scope for v2 milestones; the audit log, access controls and change management are
  designed to support them later.

## 13. Security tests that must exist

| Test | Where | Milestone |
|---|---|---|
| Durable workflow inputs and step outputs hold ids only; forget purges durable state | `packages/db` | M1 (m1-01-durable-spike, m1-03-tenancy-rls) |
| Every tenant table and partition has forced RLS; cross-tenant read returns zero rows as `offload_app` | `packages/db` | M1 (m1-03-tenancy-rls) |
| Member RLS: as member A, zero rows of member B in every C1, C2 and C6 table | `packages/db` | M1 (m1-03-tenancy-rls) |
| Resolver functions return ids only and nothing for unknown keys | `packages/db` | M1 (m1-03-tenancy-rls) |
| Audit chain verify detects edit, delete and fork | `packages/db` | M2 (m2-12-audit-anchors; the chain writer is m1-03) |
| Device token signature, nonce reuse, revoked device | `services/api` | M1 (m1-04-login-devices) |
| Transform modules cannot reach the network or the file system | `packages/routine-sdk` | M1 (m1-05-routine-contract) |
| Approval: wrong hash 403, expired 409, a claimed approval cannot be claimed again | `packages/policy` + `services/builder` | M2 |
| Deploy approval with a wrong `definition_hash` is 403 | `services/api` | M2 |
| Tamper: changed check file ends build as `tampered` | `services/builder` | M2 |
| Fake pass: a proof line printed by the worker without a fresh-sandbox re-run is not a pass | `services/builder` | M2 |
| Teeth gate refuses a check that passes on an empty workspace | `services/builder` | M2 |
| Sandbox has no credentials and no un-tokenised fixture value in env or files; outbound connection to a non-allowlisted host fails; no registry reachable | `services/builder` | M2 |
| Budget: three parallel reservations cannot exceed the remaining cap | `services/builder` | M2 |
| Broker re-check: a commit whose item hash differs from the approved one is refused; an undeclared read is refused | `services/broker` | M2 (m2-03-credential-broker) |
| Item journal: crash after `sending` yields `unknown`, never re-sent | `services/runtime` | M2 |
| EGRESS: `fetch` and socket APIs appear only in allowlisted server modules | lint test over `services/*`, `packages/*` | M2 |
| CANARY: a canary string in fixtures never appears in logs or in a column outside the content-column allowlist (C1, C2, C6 columns named) | `packages/testkit` + `packages/db` | M2 |
| Ingest rejects bad signature, replayed `seq`, skewed `sent_at`, unknown kind, leaks | `services/api` | M3 (m3-01-ingest-batches) |
| Observer sources contain no networking APIs | `apps/mac` | M3 (m3-02-mac-capture-upload) |
| Mac egress guard: an object with an unknown field or a detector hit is not sent and is counted; the local ledger holds exactly what left | `apps/mac` | M3 (m3-02-mac-capture-upload) |
| Pseudonyms: same value gives the same pseudonym across days; the key never appears in an upload | `apps/mac` | M3 (m3-02-mac-capture-upload) |
| Model router refuses unmasked names and secrets (held-out corpus) | `services/brain` | M5 (m5-03-model-router) |
| Device command: the Mac refuses a command whose item hash differs from the approved item | `apps/mac` + `services/runtime` | M6 |
| Core never imports `ee/` | `scripts/check-license-boundary.sh` | M0 (done) |

## 14. Privacy reconciliation with PR 42

PR #42 (the earlier plan of record) promised that raw data stays local, one egress guard, a readable ledger, and a
cloud with no table that can hold captured content. The owner chose a cloud brain, so v2 uploads masked screen text
and keeps the derived model. This table says plainly what changed and which controls still apply.

| PR #42 control | v2 decision |
|---|---|
| G3 raw stays on the Mac | Pixels stay (unless keyframes are opted in). **Text from the screen is uploaded**, masked and pseudonymised. C1 split: metadata 30 days, text snapshots 7 days ([OQ-02](OPEN_QUESTIONS.md#oq-02-raw-ttl-for-masked-observations-in-the-cloud)) |
| Names and paths kept locally for joins (A§6.1) | Replaced by stable keyed pseudonyms emitted on the Mac and a device-side reveal ([ADR 0028](adr/0028-stable-keyed-pseudonyms.md)) |
| One egress guard: destination and payload-class allowlist, fail closed (A§6.2) | The Mac uploader is the guard: one host, closed schemas, detectors again, fail closed. Server: lint and test ban network APIs outside listed modules ([ADR 0035](adr/0035-mac-egress-guard-and-ledger.md)) |
| G9 egress ledger, "what was sent" (A§6.4) | Local 7-day ledger of every uploaded batch, readable in the app |
| Independent second pass (A§6.3) | Server scan is a transport check only (same rules). On-device model pass evaluated in M3 by PR #42's decision rule |
| G5 zero retention, Fable and Mythos excluded | Standard retention for the tenant of one; ZDR is an operator item before any second user; product routes use Opus, Sonnet and Haiku only and the router allowlists model ids |
| Canary tests: content never in logs or unlisted columns (A§13.2) | Ported. The column allowlist names which columns may hold C1, C2 or C6 |
| No table that can hold captured content (A§13.1) | Not kept: C1, C2 and C6 tables exist by design. Each has a TTL or a forget path, member-level RLS and the canary test |
| Composio retention disclosure (A§10.4) | Kept: opaque `user_id`, explicit allowlists, no meta tools, REST only, up-to-a-year logging disclosed, ZDR add-on before any second user |
| Lane separation (A§1 principle 6) | Kept and stated ([section 7](#7-prompt-injection-defenses)); build workers are the stated exception |
| Honest limits (PRIV §10) | Ported ([section 15](#15-honest-limits)) and into onboarding ([ONBOARDING.md](ONBOARDING.md)) |
| Local brain, no build loop | Dropped by owner decision: cloud brain, sandboxed builds |

## 15. Honest limits

- Offload sees a great deal, and masked text from your screen goes to Offload's cloud. A person who should not have
  their screen observed at all (for example by employer policy or professional secrecy rules) should not install it.
  Onboarding says this.
- Masking and pseudonyms reduce what the cloud and the models see. They do not make text anonymous. Context around a
  pseudonym can still identify someone.
- The server scan only re-runs the device rules. If the Mac misses something, the server will usually miss it too.
- A Mac you do not control is not safe for this. Shared Macs and managed work Macs get a warning in onboarding.
- The audit chain proves that rows were not changed after the fact by anyone who cannot rewrite the database. It does
  not prove that against Offload as operator unless an external anchor sink is configured (EE).
- We depend on providers' terms (model provider, sandbox provider, Composio). We name them and tell you before they
  change.
- macOS, not Offload, decides when to re-ask you about screen recording. Capture falls back to the Accessibility tree
  when that happens.
