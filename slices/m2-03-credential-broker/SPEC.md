---
id: m2-03-credential-broker
title: Credential broker process with the credential vault, key providers local and aws-kms, OAuth code exchange, single-flight refresh, and the read set and item hash re-checks
milestone: M2
status: in_progress
depends_on: [m1-02-contracts-ingest, m1-03-tenancy-rls]
parallel_safe: true
human_gated: false
model_tier: sonnet
size: L
parallel_group: M2-A
owns: [services/broker/**, packages/contracts/src/broker/**, packages/db/migrations/0201_credentials.sql, packages/testkit/src/broker/**, .env.example, docs/DEPLOYMENT.md, docs/DATA_MODEL.md, docs/SECURITY_PRIVACY.md]
verify: bash slices/m2-03-credential-broker/verify.sh
min_tests: 24
paths_in_scope: [services/broker/**, packages/contracts/src/broker/**, packages/db/migrations/0201_credentials.sql, packages/testkit/src/broker/**, slices/m2-03-credential-broker/**, .env.example, docs/DEPLOYMENT.md, docs/DATA_MODEL.md, docs/SECURITY_PRIVACY.md, package.json, bun.lock]
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
      uuid as `user_id`); the response to the caller is the upstream status and body only.
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
None.
