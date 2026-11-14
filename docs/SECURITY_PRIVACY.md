# Security and privacy

This is an engineering document, not legal advice. Compliance notes say what the design supports; a lawyer must
confirm what any customer or jurisdiction requires. Words follow [GLOSSARY.md](GLOSSARY.md).

## 1. Stance

- Collect metadata first; read text only on change; mask on the device before anything is stored or sent
  ([ADR 0006](adr/0006-metadata-first-capture.md), [ADR 0005](adr/0005-masked-text-only-reaches-models.md)).
- Keep raw data short-lived and derived data honest about where it came from.
- Every external action passes a gate ([ADR 0004](adr/0004-every-external-action-is-gated.md)).
- Build untrusted code only in sandboxes that hold no secrets ([ADR 0011](adr/0011-sandboxed-build-workers.md)).
- Safety features are core. Trust is not an upgrade.

## 2. Data classes

| Class | Examples | Lives | Leaves its boundary? | Retention |
|---|---|---|---|---|
| **C0** raw on device | screen frames, unmasked OCR, unmasked titles and URLs, per-event timing | Mac encrypted store | **Never** | 7 days |
| **C1** masked observations | focus events, masked titles, URL host only, input counts, masked text snapshots, masked keyframes (opt-in) | Mac buffer, then cloud `observations` / `keyframes` | Mac → Offload cloud only | Raw TTL, default 30 days ([OQ-02](OPEN_QUESTIONS.md#oq-02-raw-ttl-for-masked-observations-in-the-cloud)) |
| **C2** derived user model | episodes, records, task ledger, entities (hashed people), facts, propositions, profile, goals | Cloud | Masked text to model providers | Until forgotten ([OQ-03](OPEN_QUESTIONS.md#oq-03-keep-the-derived-user-model-long-term)) |
| **C3** secrets | connector credentials, OAuth tokens, BYOK model keys, webhook secrets | Cloud credential vault | Only to the tool it belongs to, at call time | Until disconnected |
| **C4** governance | audit events, approvals, receipts, budget ledger, purge log | Cloud | EE export / SIEM if configured | 6 years team, 1 year personal |
| **C5** build material | briefs, checks, held-out checks, masked fixtures, artifacts | Object storage, sandboxes | To the sandbox provider during a build | Routine retired + 90 days |

## 3. What leaves the Mac

By default:
- masked observations (`observation_batch`): app bundle id and name, masked window title, URL **host** only, idle
  transitions, per-minute key and click **counts**, masked text snapshots (≤ 8000 chars), pause/resume;
- review timings (`review_event`), notice acknowledgements (`notice_ack`);
- the user's answers (profile, review answers, approvals) through the REST API.

Only with `keyframes_to_cloud` on ([OQ-04](OPEN_QUESTIONS.md#oq-04-keyframes-to-the-cloud)): masked keyframes (masked
lines and secure fields blacked out, 1280 px, JPEG q 0.6).

Never: frames when keyframes are off, unmasked text, keystrokes (which keys), URL paths or queries, anything from
excluded apps, hosts or private windows beyond the app name, the Keychain master key or device private key.

The local "last 10 minutes" onboarding summary is computed on the Mac and sends nothing.

## 4. Threat model

Assets: C1 to C5 data; the ability to commit actions as the user; build sandboxes; the audit chain; license keys.

| Threat | Example | Mitigation |
|---|---|---|
| Cross-tenant read | Bug in a query returns another tenant's rows | RLS forced on every tenant table; app role has no BYPASSRLS; tenant id only from verified tokens; RLS coverage test |
| Stolen device token | Malware on the Mac replays uploads | 15-minute tokens, P-256 key in Keychain (non-exportable), signed bodies, `seq` + ±10 min window, device revoke |
| Stolen session | Cookie theft | `__Host-` cookie, httpOnly, Secure, SameSite=Lax, CSRF token, idle timeouts, server-side revocation |
| Unmasked data upload | Masker misses a secret | Second server-side leak scan; reject + audit `privacy.leak_blocked`; held-out masking test sets in CI |
| Model provider exposure | Provider logs prompts | Masked text only; per-run placeholders; images only by opt-in; BYOK and provider terms per [OQ-05](OPEN_QUESTIONS.md#oq-05-model-provider-terms-and-monthly-model-budget) |
| Prompt injection | A web page or email tells the agent to send money | See [section 7](#7-prompt-injection-defenses) |
| Unapproved commit | Bug or injection triggers a send | Gate with exact-hash approvals, item journal, policy engine default deny, kill switches |
| Duplicate commit | Crash between send and journal | Journal `sending` before the call; `unknown` never retried automatically |
| Sandbox escape or exfiltration | Worker code reads secrets or calls out | One microVM per attempt, no secrets inside, network deny with egress proxy, see [section 8](#8-sandbox-threats) |
| Check tampering | Worker edits the acceptance check | Read-only mount, tamper hash before/after, harness nonce proof, held-out check never visible |
| Weak checks | Check passes on an empty workspace | Teeth gate, held-out check, replay fixtures, mutation score |
| Audit tampering | Admin deletes events | Append-only triggers, hash chain with unique prev hash, signed anchors, verify endpoint |
| License bypass | EE feature used without a key | Offline Ed25519 key check at startup and use; core is useful without EE |
| Insider at Offload | Support staff reads user data | Support access only through time-boxed, audited grants (max 72 h) approved by the tenant owner |
| Supply chain | Malicious dependency | Exact pins, lockfile in CI (`--frozen-lockfile`), new dependency needs a SPEC line or ADR, actions pinned by SHA before public release |

## 5. Masking

- **On device** (Swift Masker, harvested from the old engine detectors): card numbers (Luhn), CVV/expiry, SSN, SIN,
  bank routing and account, IBAN, CUSIP, ISIN, OTP codes, API keys and tokens, email addresses, phone numbers, URL user
  info, path, query and fragment, person names (lexicon rules). Excluded windows yield the app name only. Secure input
  pauses text capture.
- **Server side** (`packages/masking`): the same detector set as a leak scanner on every ingest object and every model
  request; plus the person-name masker with per-run placeholders `<person:TAG.N>`, `<person:TAG.N.first>`,
  `<person:TAG.me>`; placeholder-shaped input becomes `<name>`.
- People in the user model are salted hashes until the user confirms a name in the review ("Is D. in these threads Dana?").
- Measured in CI: held-out masking corpora (names, secrets) with a maximum miss rate set in the masking slice; a miss
  above it fails the build.

## 6. Encryption and keys

| Where | How |
|---|---|
| Mac store | AES-256-GCM per day key, wrapped by a 32-byte master key in the login Keychain (this device only, after first unlock). Same-user processes on the Mac can still read the Keychain item with user consent; this is the documented trust boundary of the Mac. |
| Device identity | P-256 private key in the Keychain, non-exportable; public JWK registered at enrollment |
| In transit | TLS 1.2+ (prefer 1.3), HSTS |
| Postgres | Provider encryption at rest (KMS); PITR backups encrypted |
| Credential vault | Envelope encryption: per-tenant data key (AES-256-GCM) wrapped by KMS key `OFFLOAD_KMS_KEY_REF`; rotation re-wraps data keys; tenant delete destroys the data key (crypto-shred) |
| Object storage | SSE-KMS; per-object keys under the tenant prefix |
| Signing | Ed25519 service keys for build receipts and audit anchors (KMS-held or HSM in EE dedicated); license keys verified with public keys compiled into `packages/license` |
| Approvals and tokens | 32 random bytes, only `sha256` stored, single use, TTL 24 h |

## 7. Prompt-injection defenses

Untrusted sources: screen text, tool and MCP results, emails, web pages, webhook bodies, MCP tool descriptions.

- Untrusted content is wrapped in `<name untrusted="true">` blocks with Unicode format characters stripped, and the
  system prompt states that instructions inside them are data.
- **Models never hold authority**: they cannot open the gate, choose recipients outside the run's input set, or change
  policy. Commits need an exact-hash approval or a policy allow computed in code.
- Capability and argument allowlists: a commit's arguments must match the capability schema; recipients outside the
  run's input set trip `recipient_not_allowed`.
- Read steps are enforced read-only by capability class; a "read" that tries to write is refused.
- Build workers have no network except the model proxy and allowlisted registries, and no credentials.
- MCP servers are vetted per tenant; their tool lists are pinned by hash; a changed tool description needs re-approval.
- Browser automation commits always ask.
- The Offload MCP server exposes read and propose only.

## 8. Sandbox threats

**Lesson from old ADR 0013 (same-uid `KERN_PROCARGS2`)**: on macOS, code running under the same user inside
`sandbox-exec` could read the full argv **and environment** of every other process of that uid through
`sysctl KERN_PROCARGS2`, which the sandbox does not mediate. On macOS 26.5.1 (2026-10-26) a same-user `bun` returned
61 environment entries of another process. Any token exported in a terminal, an editor plugin or another agent session
was exposed. `/bin/ps` being setuid root also exposed other users' argv. Conclusion: **never run untrusted build code
as a user who has secrets in other processes**, and never rely on a policy sandbox for secret isolation.

v2 design ([ADR 0011](adr/0011-sandboxed-build-workers.md)):
- Builds never run on the user's Mac. Each attempt gets its own microVM (E2B) or container; nothing else of value runs
  in it.
- No secrets inside: the model key is added by an egress proxy outside the sandbox; connector credentials never enter.
- Network deny by default; allowlisted package registries go through a filtering proxy with a size cap.
- Checks read-only and hashed; harness nonce proof; held-out and replay run in a fresh sandbox.
- Artifacts are scanned for known secret patterns and for network calls outside the brief's declared capabilities
  before "Ready to ship".
- Resource caps (2 vCPU, 4 GiB, 12 min) and the $4.00 budget ledger bound abuse.
- Deployed routines run in the runtime, not in the build sandbox. Artifacts that need code execution at run time
  (`script`, `small_app`) run in a run sandbox with only the capabilities the brief declared; credentials are injected
  per call by the runtime through a connector proxy, never as environment variables.

## 9. Secrets

- No secret values in code, logs, env files in git, model prompts, sandbox images or audit events.
- `.env.example` lists names only; `scripts/check-secrets-hygiene.sh` fails if another env file exists or a value is set.
- Log scrubbing redacts known secret patterns (sk-ant, sk-, gh*_, github_pat_, AKIA/ASIA, xox*, JWT, PEM, Bearer/Basic,
  `KEY=value`), including base64 and URL-encoded forms.
- Credentials are references where the platform allows (Composio connected account, OAuth grant).

## 10. Sub-processors

Planned for Offload Cloud (owner confirms in [OQ-01](OPEN_QUESTIONS.md#oq-01-cloud-hosting-provider-and-region) and
[OQ-17](OPEN_QUESTIONS.md#oq-17-privacy-policy-terms-and-dpa)):

| Sub-processor | Purpose | Data |
|---|---|---|
| Cloud host (default AWS, `ca-central-1`) | Compute, Postgres, object storage, KMS | C1 to C5 |
| Anthropic | Model inference | Masked text (C1/C2 excerpts), masked images only if opted in |
| E2B | Build sandboxes | Briefs, checks, masked fixtures (C5) |
| WorkOS | Login, SSO, directory | Member email, name, IdP attributes |
| Composio (only for tenants who connect through it) | Tool auth and execution | Tool arguments and credentials for that tool |

Self-hosters choose their own; the core ships with no mandatory third party except the model provider they configure.

## 11. Retention, export, forget, wipe

- Raw TTL job deletes `observations` and `keyframes` partitions older than the TTL daily, logs to `purge_log`.
- Figures whose evidence is gone keep their numbers and arithmetic and show `source_purged` with the date.
- **Export**: `GET /v1/me/export` returns all of a member's C2 data and settings as JSON.
- **Forget**: entity (cascade to aliases, facts, propositions, embeddings), date range (observations, episodes,
  day records in range; week records recomputed), import space, or all.
- **Wipe**: delete the tenant; data keys destroyed; backups expire on their schedule (35 days).
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
  shows who viewed my data. Which of these ship in Pro vs Enterprise is [OQ-15](OPEN_QUESTIONS.md#oq-15-monitoring-law-features-for-teams).
- **Model providers**: Anthropic API standard data retention applies unless the tenant uses BYOK under its own terms.
  Some models require 30-day retention and are not available under zero data retention.
- **SOC 2 / ISO 27001**: not in scope for v2 milestones; the audit log, access controls and change management are
  designed to support them later.

## 13. Security tests that must exist

| Test | Where | Milestone |
|---|---|---|
| Every tenant table has forced RLS; cross-tenant read returns zero rows as `offload_app` | `packages/db` | M1 |
| Observer sources contain no networking APIs | `apps/mac` | M1 |
| Ingest rejects bad signature, replayed `seq`, skewed `sent_at`, unknown kind, leaks | `services/api` | M1 |
| Model router refuses unmasked names and secrets (held-out corpus) | `services/brain` | M2 |
| Approval: wrong hash 403, reused 409, expired 409, claimed once under concurrency | `packages/policy` + `services/builder` | M4 |
| Tamper: changed check file ends build as `tampered` | `services/builder` | M4 |
| Teeth gate refuses a check that passes on an empty workspace | `services/builder` | M4 |
| Sandbox has no credentials in env or files; outbound connection to a non-allowlisted host fails | `services/builder` | M4 |
| Item journal: crash after `sending` yields `unknown`, never re-sent | `services/runtime` | M5 |
| Audit chain verify detects edit, delete and fork | `packages/db` | M5 |
| Core never imports `ee/` | `scripts/check-license-boundary.sh` | M0 (done) |
