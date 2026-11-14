# 0034. Credential broker and key providers

Status: accepted, revised 2026-11-14 · Date: 2026-11-14

## Context
The vault decrypted credentials inside the process that also runs model steps, so "models never open a gate" was a
convention, not a boundary. The `credentials` table was OAuth-shaped and thin, and "self-host with only Postgres" had
no key provider without a cloud KMS ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(3)).

## Decision
- **`services/broker`** is a small separate process, the one exception to the modular monolith
  ([ADR 0023](0023-service-layout.md)). It **alone holds decrypt rights** for credentials and fixture token maps. The
  main process talks to it over a local socket with a service token.
- For a **commit**, the broker re-checks the approval (or policy allow) and that the call's argument hash equals the
  approved item hash before it uses a credential. For a **read**, it checks the capability is in the run's declared read
  set (or the gate is in mode `read` for fixture capture and instant read). Credentials never leave the broker except
  inside the outbound request it makes.
- **Key provider port** `KeyProvider { wrap, unwrap }`:
  - `aws-kms` (Offload Cloud default, `OFFLOAD_KMS_KEY_REF`), `gcp-kms`;
  - `local`: a 32-byte master key read from `OFFLOAD_MASTER_KEY_FILE`, readable only by the broker's OS user, for
    self-host with only Postgres.
  Envelope encryption: a per-tenant data key (AES-256-GCM) wrapped by the provider; KMS encryption context
  `tenant_id`. Tenant delete destroys the data key (crypto-shred).
- **`credentials` columns** ([DATA_MODEL.md](../DATA_MODEL.md#8-connectors-governance-measurement-privacy)):
  `ciphertext`, `nonce`, `wrapped_dek`, `key_provider`, `key_ref`, `scopes[]`, `expires_at`, `refresh_state`
  (`ok`, `refreshing`, `failed`, `revoked`), `refresh_lease_until`, `last_refreshed_at`, `created_at`, `rotated_at`.
- **Single-flight refresh without holding a transaction**: a short transaction sets `refresh_state = 'refreshing'` and
  `refresh_lease_until = now() + 30 s` only if no live lease exists; the refresh call happens outside any transaction;
  a second short transaction writes the new token and clears the lease. No network I/O inside `withTenant`
  ([ADR 0013](0013-tenancy-and-rls.md)).
- Model keys for BYOK are credentials too and are used only through the broker.

## Consequences
- A bug or injection in the main process cannot read a credential; it can only ask the broker for an approved call.
- Self-host needs a key file, kept off the database host's backups.

## Alternatives considered
- Decrypt in the runtime module (the previous version): the boundary was a convention.
- `OFFLOAD_KMS_KEY_REF` only: no Postgres-only self-host.
- Row lock held during refresh: pins a pooled connection across a network call.

## Sources
[Design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(3); PR #42 A§13.3 (connector broker); old `brain/src/connectors/secrets.ts`.

## Revisions
- 2026-11-14 (decision pass D): on Kubernetes with a KMS key provider the broker runs as its own Deployment and
  ServiceAccount (workload identity is per pod), reached over a namespace-internal Service with the service token and
  mTLS instead of a local socket ([ADR 0037](0037-hosting-cloud-and-self-host-parity.md)).
