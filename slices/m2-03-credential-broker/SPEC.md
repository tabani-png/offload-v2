---
id: m2-03-credential-broker
title: Credential broker process with the credential vault, key providers local and aws-kms, OAuth code exchange, single-flight refresh, and the read set and item hash re-checks
milestone: M2
status: done
depends_on: [m1-02-contracts-ingest, m1-03-tenancy-rls]
parallel_safe: true
human_gated: false
model_tier: sonnet
size: L
parallel_group: M2-A
owns: [services/broker/**, packages/contracts/src/broker/**, packages/db/migrations/0201_credentials.sql, packages/testkit/src/broker/**, .env.example, docs/DEPLOYMENT.md, docs/DATA_MODEL.md, docs/SECURITY_PRIVACY.md]
verify: bash slices/m2-03-credential-broker/verify.sh
min_tests: 24
paths_in_scope: [services/broker/**, packages/contracts/src/broker/**, packages/db/migrations/0201_credentials.sql, packages/testkit/src/broker/**, slices/m2-03-credential-broker/**, packages/db/tests/m1-03-tenancy-rls/rls.test.ts, .env.example, docs/DEPLOYMENT.md, docs/DATA_MODEL.md, docs/SECURITY_PRIVACY.md, package.json, bun.lock]
paths_out_of_scope: [ee/**, apps/**, services/api/**, services/brain/**, services/builder/**, services/runtime/**, packages/connectors-sdk/**, packages/masking/**, packages/db/src/**, packages/contracts/src/index.ts, packages/contracts/scripts/**, packages/contracts/schemas/**, packages/testkit/src/index.ts, docs/adr/**]
red_tests: [KEY, VAULT, BROKER, OAUTH, REFRESH]
---

# m2-03-credential-broker

## Summary
The one process with decrypt rights, for the [M2 hand-fed loop](../../docs/ROADMAP.md#m2-hand-fed-loop). Implements
[ADR 0034](../../docs/adr/0034-credential-broker-and-key-providers.md) (broker, key provider port, envelope encryption,
single-flight refresh), the broker part of [ARCHITECTURE section 10](../../docs/ARCHITECTURE.md#10-connector-and-tool-layer),
the `credentials` table in [DATA_MODEL section 8](../../docs/DATA_MODEL.md#8-connectors-governance-measurement-privacy),
the C3 rules in [SECURITY_PRIVACY sections 6 and 9](../../docs/SECURITY_PRIVACY.md#9-secrets) and the broker row of
[section 13](../../docs/SECURITY_PRIVACY.md#13-security-tests-that-must-exist). The broker is the exception to the
modular monolith in [ADR 0023](../../docs/adr/0023-service-layout.md).

**Model tier.** ROADMAP lists this task as "Opus plan, Sonnet build": this SPEC is the Opus plan, a Sonnet worker
implements it (`model_tier: sonnet`), and Opus reviews. It is security-sensitive (vault, credentials), so it also gets
a security review against SECURITY_PRIVACY section 13 before `done`.

`aws-kms` is behind a `KmsClient` interface with a fake in `packages/testkit/src/broker/`. Every slice test uses the
fake. One live test, tagged `LIVE:`, runs against the real key only when the operator has set up the KMS key (operator
item O7, [OQ-01](../../docs/OPEN_QUESTIONS.md#oq-01-cloud-hosting-provider-and-region) default AWS `ca-central-1`) and
credentials are present; otherwise it skips. It is not a red-test tag and does not count toward `min_tests`.

Old code: `brain/src/connectors/secrets.ts` is **keep** in [MIGRATION section 2.6](../../docs/MIGRATION.md#26-brain-bun--ts--services-packages)
for its secret-handling rules only (it used Keychain references; the vault replaces that). Nothing is ported from
PRs #43 to #45. The broker approval rules of old `control/src/modules/broker/*` are **rewrite**
([MIGRATION section 2.7](../../docs/MIGRATION.md#27-control-plane-control-stage-2--services-packages-ee)).

## Contract
- Delete `services/broker/tests/smoke.test.ts` and replace the TODO marker in `services/broker/src/index.ts` (first
  slice in this package).
- Dependency (exact pin, `services/broker/package.json`): `@aws-sdk/client-kms` `3.1169.0`, imported only by
  `services/broker/src/keys/aws-kms-client.ts`, the production `KmsClient`. Everything else uses Bun and `node:crypto`.
- **Shared files in M2-A**: this slice does not edit package barrels (`packages/contracts/src/index.ts`,
  `packages/testkit/src/index.ts`), the JSON Schema generator or `packages/contracts/schemas/**` (owned by m2-02).
  Broker protocol shapes are zod in `packages/contracts/src/broker/` and imported by subpath; they are spoken only
  between TypeScript processes, so no JSON Schema is generated for them in this slice. It owns `.env.example`,
  `docs/DEPLOYMENT.md`, `docs/DATA_MODEL.md` and `docs/SECURITY_PRIVACY.md` in M2-A.
- **Process**: `bun services/broker/src/main.ts` (`offload broker`). Listens with `Bun.serve({ unix })` on
  `OFFLOAD_BROKER_SOCKET`, socket file mode `0600`. Every request carries `Authorization: Bearer <service token>`; the
  token is read at start from the file named by `OFFLOAD_BROKER_SERVICE_TOKEN_REF` and compared in constant time; a
  missing or wrong token is 401 before any lookup. (mTLS on Kubernetes, ADR 0034 revision, is out of scope.)
- **Config names** added to `.env.example` and [DEPLOYMENT section 11.3](../../docs/DEPLOYMENT.md#113-environment-variables)
  (names only, read by `broker` only): `OFFLOAD_BROKER_SERVICE_TOKEN_REF`, `OFFLOAD_KEY_PROVIDER` (`local` or
  `aws-kms`), `OFFLOAD_GOOGLE_CLIENT_ID`, `OFFLOAD_GOOGLE_CLIENT_SECRET_REF` (the owner's Internal OAuth client, operator
  item O5). Existing names used: `OFFLOAD_MASTER_KEY_FILE`, `OFFLOAD_KMS_KEY_REF`, `COMPOSIO_API_KEY`, `DATABASE_URL`,
  `DATABASE_APP_ROLE` (set to `offload_broker` for this process). Code never prints an env value, including to check it.
- **Migration** `packages/db/migrations/0201_credentials.sql`:
  - `credentials` exactly as DATA_MODEL section 8, plus `UNIQUE (tenant_id, connection_id)`.
  - `oauth_requests (tenant_id, state_sha256)` with `connection_id`, `member_id`, `provider`, `code_verifier`,
    `redirect_uri`, `expires_at` (10 minutes), `used_at` (`R-session`). Added to DATA_MODEL section 8 by this slice.
  - Both tables: `ENABLE` + `FORCE ROW LEVEL SECURITY`, policy `tenant_isolation`.
  - New role `offload_broker` (not owner, no `BYPASSRLS`): SELECT, INSERT, UPDATE, DELETE on `credentials` and
    `oauth_requests`; SELECT and `UPDATE (state)` on `connections` (table from m2-02's `0200`; if m2-02 has not landed,
    this grant moves to a `0202` migration added after it, recorded under "Scope changes"); INSERT and SELECT on
    `audit_events`. `offload_app` gets **no** privilege on `credentials` or `oauth_requests`. Recorded in the
    `credentials` row of DATA_MODEL section 8 and in SECURITY_PRIVACY section 9 (the role list itself is in
    [ADR 0013](../../docs/adr/0013-tenancy-and-rls.md), which this slice does not edit; the reviewer adds a revision
    line there).
- **Key providers** (`services/broker/src/keys/`), port `KeyProvider { name, keyRef, wrap(dek, ctx), unwrap(wrapped,
  ctx) }` with `ctx = { tenant_id }`:
  - `local`: master key from `OFFLOAD_MASTER_KEY_FILE`; refused at start unless the file is exactly 32 bytes, owned by
    the process user and has no group or other permission bits. Wrap = AES-256-GCM with a random 12-byte nonce and AAD
    = `tenant_id`.
  - `aws-kms`: `GenerateDataKey` (AES_256) and `Decrypt` through `KmsClient` with `KeyId = OFFLOAD_KMS_KEY_REF` and
    `EncryptionContext = { tenant_id }`. `gcp-kms` is out of scope.
- **Vault** (`services/broker/src/vault/`): per credential row a fresh 32-byte data key; plaintext secret encrypted with
  AES-256-GCM, random 12-byte `nonce`, AAD = `tenant_id || 0x00 || connection_id`; `wrapped_dek`, `key_provider`,
  `key_ref` stored. A row whose `key_provider` or `key_ref` differs from the configured provider fails closed (rotation
  is a later slice). `shred(tenant_id, connection_id)` deletes the row (its data key goes with it) and audits
  `credential.shredded`; `shredTenant(tenant_id)` deletes every row of the tenant.
- **RPC** (`packages/contracts/src/broker/`, JSON over HTTP on the socket, each body names `tenant_id`; the broker runs
  every query inside `withTenant` and every outbound call outside it):
  - `POST /oauth/begin { tenant_id, member_id, connection_id, provider, scopes[], redirect_uri }` → `{ authorize_url }`
    (PKCE S256; `state` 32 random bytes, only its sha256 stored; verifier kept in `oauth_requests`).
  - `POST /oauth/finish { tenant_id, state, code }` → `{ connection_id, account_label, account_hash, scopes[] }`. The
    code exchange uses the client secret inside the broker; tokens go straight into the vault; `connections.state`
    becomes `active`. A used or expired state stores nothing.
  - `POST /credentials/api-key { tenant_id, connection_id, api_key }` → `{ account_label, account_hash }`.
  - `POST /credentials/shred { tenant_id, connection_id }` → 204.
  - `POST /tools/list { tenant_id, connection_id }` → raw tool list (same outbound rules as reads).
  - `POST /call { tenant_id, kind: "read" | "commit", gate_mode: "read" | "live", connection_id, capability,
    arguments, run_id? , fixture_set_id?, approval_id?, request: { method, url, headers, body } }` → the upstream status
    and body, never a credential. Before any decrypt:
    - `read`: the capability must be in the run's declared read set (`RunScopeSource.readSet(tenant_id, run_id)`), or
      `gate_mode` is `read` with a `fixture_set_id` (`RunScopeSource.fixtureScope`). Otherwise 403 `read_not_declared`.
    - `gate_mode: "read"` refuses every commit capability (403 `gate_read_only`).
    - `commit`: the broker computes `item_hash = sha256Hex(jcs(arguments))` itself (a caller-supplied hash is ignored)
      and asks `ApprovalVerifier.check(tenant_id, approval_id, item_hash)`; anything but `ok` is refused with that code
      and the status API.md gives it (403 `hash_mismatch`, 403 `forbidden` for no approval, 409 `approval_used`,
      409 `approval_expired`), and audit `broker.refused`. Broker-only codes (`read_not_declared`, `gate_read_only`,
      `host_not_allowed`, `key_provider_mismatch`) never reach a public response.
    - The request URL host must be in the provider's host allowlist (`services/broker/src/egress/hosts.ts`, for
      example `sheets.googleapis.com`, `api.stripe.com`, `backend.composio.dev`, the Notion and Linear MCP hosts);
      otherwise 403 `host_not_allowed` and no credential is decrypted.
    - The credential is added only to the outbound request's auth header (or Composio's `x-api-key` with the member
      uuid as `user_id`); the response to the caller is the upstream status and body only. The broker always overwrites
      `user_id` with the connection's member uuid, in a JSON object body and in the query string; a caller-supplied
      `user_id` never survives, and a composio call on a connection with no member uuid is refused (400
      `invalid_request`, upstream not called).
  - `RunScopeSource` and `ApprovalVerifier` are ports. Their Postgres implementations land with the tables they read
    (approvals in m2-06, routine versions and runs in m2-09/m2-10, fixture sets in m2-04). This slice ships fakes in
    `packages/testkit/src/broker/`.
- **Egress**: `fetch` is used only in `services/broker/src/egress/` (the broker is on the server egress allowlist in
  [SECURITY_PRIVACY section 9](../../docs/SECURITY_PRIVACY.md#9-secrets)).
- **Refresh** (`services/broker/src/refresh.ts`), as ADR 0034: short transaction sets `refresh_state = 'refreshing'`
  and `refresh_lease_until = now() + 30 s` only if no live lease exists; the refresh call runs outside any transaction;
  a second short transaction writes the new token (`last_refreshed_at`, `refresh_state = 'ok'`) and clears the lease. A
  refusal from the provider sets `refresh_state = 'failed'` and `connections.state = 'needs_reauth'`. Callers that
  find a live lease wait for it (bounded) and re-read.
- **Logs**: one logger, `services/broker/src/log.ts`, scrubbing the patterns in SECURITY_PRIVACY section 9 and logging
  ids and hashes only. Audit actions: `credential.stored`, `credential.shredded`, `credential.refreshed`,
  `broker.refused`, details ids and hashes only.
- **Fakes** (`packages/testkit/src/broker/`): `FakeKms` (enforces key id and encryption context, records calls),
  `fakeUpstream()` (a `Bun.serve` on 127.0.0.1 that records the headers it receives), `FakeOAuthServer` (authorize and
  token endpoints), `fakeRunScope()`, `fakeApprovals()`.
- Live test (not a red-test tag): `LIVE: aws-kms wraps and unwraps a data key with the configured key`, in the same
  folder, `test.skipIf(...)` when `OFFLOAD_KMS_KEY_REF` or AWS credentials are absent (presence checked as a boolean,
  never printed). Run once by the operator before M2 exit and recorded in the slice's PR.

## Red tests (write these first, run them, see them fail)
Folder: `services/broker/tests/m2-03-credential-broker/` (real Postgres 17 at `DATABASE_URL`; `FakeKms`; no network
except loopback fakes).

| Tag | Test name | Asserts |
|---|---|---|
| KEY | KEY: the local provider refuses a master key file readable by group or others | start fails, nothing listens |
| KEY | KEY: the local provider refuses a key file that is not exactly 32 bytes | |
| KEY | KEY: a data key wrapped for tenant A does not unwrap for tenant B | `local` and `aws-kms` (fake) |
| KEY | KEY: aws-kms sends the configured key id and tenant_id as the encryption context | `FakeKms` call log |
| KEY | KEY: a credential row from another key provider fails closed | no plaintext, error `key_provider_mismatch` |
| VAULT | VAULT: credential plaintext never appears in logs, events or model prompts | canary secret searched in captured logs, `audit_events`, `events_outbox`, every RPC response and error body |
| VAULT | VAULT: offload_app cannot select, insert or update credentials or oauth_requests | permission denied for each |
| VAULT | VAULT: a ciphertext does not decrypt under another connection's AAD | |
| VAULT | VAULT: shred deletes the credential and a later call on that connection fails | audit `credential.shredded` |
| BROKER | BROKER: a commit whose item hash is not in the approved batch is refused by the broker | ROADMAP M2 test; 403 `hash_mismatch`, upstream not called |
| BROKER | BROKER: the broker hashes the arguments itself and ignores a caller-supplied item hash | |
| BROKER | BROKER: a read outside the run's declared read set is refused | 403 `read_not_declared` |
| BROKER | BROKER: gate mode read refuses every commit capability | 403 `gate_read_only` |
| BROKER | BROKER: a request without the service token or with a wrong one is 401 before any lookup | no query issued |
| BROKER | BROKER: a request to a host outside the provider allowlist is refused and nothing is decrypted | `FakeKms` saw no unwrap |
| BROKER | BROKER: the credential reaches only the upstream auth header and never the caller | `fakeUpstream` saw it; the RPC response did not |
| BROKER | BROKER: the socket file is mode 0600 | |
| BROKER | BROKER: a caller-supplied user_id in the composio body is replaced by the member uuid | |
| BROKER | BROKER: a caller-supplied user_id in the composio query string is replaced by the member uuid | |
| BROKER | BROKER: a composio call on a connection with no member uuid is refused and nothing is sent | 400 `invalid_request` |
| OAUTH | OAUTH: begin returns an authorize_url with PKCE S256 and a single-use state | only `state_sha256` stored |
| OAUTH | OAUTH: finish with a used or expired state is refused and stores nothing | 10 minutes, fake clock |
| OAUTH | OAUTH: finish exchanges the code with the client secret inside the broker and stores the tokens encrypted | `connections.state = active`; tokens only as ciphertext |
| REFRESH | REFRESH: two concurrent refreshes make one provider call | single-flight lease |
| REFRESH | REFRESH: an expired lease lets the next caller refresh | 30 s, fake clock |
| REFRESH | REFRESH: the refresh call runs outside any transaction | fetch guard from m1-03 |
| REFRESH | REFRESH: a refused refresh marks the credential failed and the connection needs_reauth | |

## Out of scope
`gcp-kms`; key rotation and re-wrapping; mTLS and the Kubernetes Deployment ([ADR 0037](../../docs/adr/0037-hosting-cloud-and-self-host-parity.md));
fixture token maps and C6 encryption (m2-04, which reuses the vault and key providers); BYOK model keys (router,
later); the Postgres implementations of `RunScopeSource` and `ApprovalVerifier` (m2-04, m2-06, m2-10); the API routes
and the `BrokerPort` client wiring (m2-02 and m2-04); connector request building (connectors-sdk); Composio and MCP
session details beyond adding the credential and `user_id`; the per-tenant data key wording in ADR 0034 versus the
per-row `wrapped_dek` column (see "Scope changes" if the reviewer asks for a per-tenant key).

## Verify
`bash slices/m2-03-credential-broker/verify.sh` (needs `DATABASE_URL`, Postgres 17). The `LIVE:` test skips without
KMS credentials and is not counted.

## Scope changes
- Widened `paths_in_scope` by `packages/db/tests/m1-03-tenancy-rls/rls.test.ts`. The m1-03 tests "RLS: offload_app with tenant
  A reads zero rows of tenant B" and "RLS: with app.tenant_id unset offload_app reads zero rows" read every tenant table as
  `offload_app`, but this slice's contract is that `offload_app` has no privilege on `credentials` or `oauth_requests`
  (SECURITY_PRIVACY section 9), so they failed with `permission denied for table credentials`. Those two tables are now left
  out of the three app-readable loops (`BROKER_ONLY_TABLES`); every other m1-03 check (FORCE RLS, policy shape) still covers
  them, and the broker's own tenant wall is tested here (`VAULT: offload_broker ...`).
- `offload_broker` cannot be created by migration `0201` (the migrator has no `CREATEROLE`), and `packages/db/src/roles.ts`
  (`ROLES`, `bootstrapRoles`) is out of scope, so the role is created by an administrator (testkit: `ensureBrokerRole`) and
  the grants in `0201` run only when it exists (notice otherwise). Adding it to `bootstrapRoles` is a follow-up for the slice
  that owns `packages/db/src`.
- `credentials` has primary key `(tenant_id, connection_id)` (the DATA_MODEL key) and also the `UNIQUE (tenant_id,
  connection_id)` this SPEC asks for.
- `aws-kms` wraps through the port's `wrap(dek, ctx)` by asking KMS for a data key and using it as a one-time wrapping key
  (the vault's data key is made by the vault, KMS generates its own); see `services/broker/src/keys/aws-kms.ts`.
- Test fixes after the red commit (harness and timing, not behaviour): the single-flight test's provider delay (40 ms, under
  the 80 ms lease wait), the composio test sets its connection `active`, the foreign-host test accepts 400 for an unparsable
  url, and extra tests were added (composio, tools/list, scrubber, egress lint, tenant wall, LIVE).

## Security review (SECURITY_PRIVACY section 13, broker row)
Recorded 2026-11-15 against `services/broker/src/**` at the review commit, before `done`. Reviewer: the slice builder's
read of the code plus the red tests below; the AGENTS.md independent reviewer pass (Opus) still applies at merge.
- Item hash and read set: `handleCall` computes `item_hash = sha256Hex(jcs(arguments))` itself, asks `ApprovalVerifier`
  before any decrypt, and refuses an undeclared read before any decrypt. Covered by `BROKER: a commit whose item hash is
  not in the approved batch is refused`, `...hashes the arguments itself`, `...outside the run's declared read set`.
- **Finding (residual, accepted for this slice, must close before M2 exit): the checks bind to the declared
  `capability` and `arguments`, not to the outbound `request`.** The SPEC's contract checks the read set against
  `capability` and the approval against `jcs(arguments)`; `request.method`, `request.url` path and `request.body` are
  built by the caller (connectors-sdk, out of scope) and the broker only checks the host allowlist. So a compromised
  main process can (a) send `kind: "read"` with a declared capability and a POST/PUT/PATCH/DELETE or a write path on an
  allowlisted host, which carries the credential and writes upstream with no approval, or (b) reuse an approved
  `arguments` object with a different `request.body`. This narrows, and does not meet, ADR 0034 line 34 ("it can only
  ask the broker for an approved call"): today it can ask for any call on an allowlisted host that names a declared
  capability. Not closed here because binding the request to the capability needs a capability-to-request-shape table
  (method, path template, body derived from `arguments`) that belongs to the connector contract (m2-04 and
  connectors-sdk, both out of scope), and `docs/adr/**` is out of scope. See the first Follow-up.
- Composio identity: the member uuid is the Composio `user_id` and is enforced, not defaulted. `handleCall` overwrites
  `user_id` in the body and the query string and refuses a composio call with no member uuid (round 1 verifier defect,
  fixed test first; covered by the three `BROKER: ... composio ... member uuid` tests).
- Order of checks: service token (constant time, sha256 then `timingSafeEqual`) before parse or lookup; host allowlist
  before decrypt; credential used only in `handleCall` after both. No finding.
- Egress: `fetch` only in `egress/http.ts`, `redirect: "manual"` so a credential is never replayed to another host,
  bounded body and 30 s timeout. Upstream bodies are scrubbed of the credential (plain, URL-encoded, base64) before they
  reach the caller. No finding.
- Errors and logs: unknown errors log the class and SQLSTATE only; the logger scrubs section 9 patterns. No finding.
- Socket: umask `0177` during `Bun.serve`, then `chmod 0600`; stale socket removed only if it is a socket. No finding.
- Residual, accepted: `redact` skips secrets shorter than 4 characters; the scrub is a backstop, not the control (the
  control is that the credential is never placed in anything returned). `offload_broker` needs an administrator-created
  role until `bootstrapRoles` owns it (see Follow-ups).

## Follow-ups (owned by another slice, needed before M2 exit)
- **Bind the outbound request to the checked capability and arguments** (closes the finding above; m2-04 with
  connectors-sdk, plus a revision line in ADR 0034). Options: the broker builds `request` itself from a pinned
  per-capability template and `arguments`; or the caller sends `request` and the broker verifies it against that
  template. Minimum rules: a `read` capability may only use GET, or a POST on a path the template marks read-only (MCP
  `tools/list`, `tools/call` for a read-class tool); a `commit` hash covers `arguments` and the request body is derived
  from it or hashed with it (`item_hash = sha256Hex(jcs({arguments, request}))` if the caller keeps building it). Add
  red tests: a `read` with a POST write path is refused; an approved `arguments` with a changed body is refused.
- Add `offload_broker` to `ROLES` and `bootstrapRoles` in `packages/db/src/roles.ts` (out of scope here), so `0201` grants
  run on a fresh deployment instead of printing a notice. Until then DEPLOYMENT.md tells the operator to create the role
  before running migrations, or to re-run the `0201` grants.
- The independent Opus reviewer pass (AGENTS.md) and the operator's one-time `LIVE:` aws-kms run are recorded in the PR.
