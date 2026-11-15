import type { Pool } from "pg";
import { appendAudit, withTenant, type TenantContext, type Tx } from "@offload/db";
import type { KeyProvider } from "@offload/contracts/src/broker/index.ts";
import { BrokerError } from "../errors.ts";
import type { Logger } from "../log.ts";
import { aadFor, newDataKey, open, seal } from "./crypto.ts";

/**
 * The credential vault (ADR 0034). Per credential row: a fresh 32-byte data key, the secret sealed with AES-256-GCM
 * (random nonce, AAD = tenant_id || 0x00 || connection_id), the data key wrapped by the key provider. Key-provider
 * calls (which may be network I/O) run outside any transaction; each database step is one short transaction.
 */

export type VaultSecret =
  | { kind: "api_key"; api_key: string }
  | { kind: "oauth"; access_token: string; refresh_token?: string };

export interface VaultMeta {
  scopes: string[];
  expiresAt: Date | null;
}

export interface CredentialMeta {
  scopes: string[];
  expiresAt: Date | null;
  refreshState: "ok" | "refreshing" | "failed" | "revoked";
  refreshLeaseUntil: Date | null;
  lastRefreshedAt: Date | null;
}

export interface VaultDeps {
  pool: Pool;
  keys: KeyProvider;
  clock: { now(): Date };
  logger: Logger;
}

export const BROKER_PRINCIPAL = "service:broker";

export function brokerCtx(tenantId: string): TenantContext {
  return { tenantId, principalId: BROKER_PRINCIPAL, memberId: null, tenantRole: "service" };
}

/** Raw credentials row as the broker reads it. */
export interface CredentialRow {
  ciphertext: Buffer;
  nonce: Buffer;
  wrapped_dek: Buffer;
  key_provider: string;
  key_ref: string;
  scopes: string[];
  expires_at: Date | null;
  refresh_state: CredentialMeta["refreshState"];
  refresh_lease_until: Date | null;
  last_refreshed_at: Date | null;
}

export function metaOf(r: CredentialRow): CredentialMeta {
  return {
    scopes: r.scopes, expiresAt: r.expires_at, refreshState: r.refresh_state, refreshLeaseUntil: r.refresh_lease_until,
    lastRefreshedAt: r.last_refreshed_at,
  };
}

function encode(secret: VaultSecret): Buffer {
  return Buffer.from(JSON.stringify(secret), "utf8");
}

function decode(bytes: Buffer): VaultSecret {
  const v = JSON.parse(bytes.toString("utf8")) as VaultSecret;
  if (v.kind !== "api_key" && v.kind !== "oauth") throw new Error("credential payload is malformed");
  return v;
}

export interface SealedSecret {
  ciphertext: Buffer;
  nonce: Buffer;
  wrappedDek: Buffer;
}

export class Vault {
  constructor(private readonly d: VaultDeps) {}

  /** Seals `secret` for one connection. Key-provider I/O happens here, so call it outside a transaction. */
  async seal(tenantId: string, connectionId: string, secret: VaultSecret): Promise<SealedSecret> {
    const dek = newDataKey();
    try {
      const wrapped = await this.d.keys.wrap(dek, { tenant_id: tenantId });
      const sealed = seal(dek, encode(secret), aadFor(tenantId, connectionId));
      return { ciphertext: sealed.ciphertext, nonce: sealed.nonce, wrappedDek: Buffer.from(wrapped) };
    } finally {
      dek.fill(0);
    }
  }

  /** Opens a row: checks the key provider and key_ref first (fail closed), unwraps outside any transaction, then decrypts. */
  async openRow(tenantId: string, connectionId: string, row: CredentialRow): Promise<VaultSecret> {
    if (row.key_provider !== this.d.keys.name || row.key_ref !== this.d.keys.keyRef) {
      throw new BrokerError("key_provider_mismatch", "the credential was stored under another key provider or key");
    }
    let dek: Uint8Array | undefined;
    try {
      dek = await this.d.keys.unwrap(row.wrapped_dek, { tenant_id: tenantId });
      return decode(open(dek, row.ciphertext, row.nonce, aadFor(tenantId, connectionId)));
    } catch (e) {
      if (e instanceof BrokerError) throw e;
      this.d.logger.error("vault.open_failed", { tenant_id: tenantId, connection_id: connectionId });
      throw new BrokerError("server_error", "the credential cannot be decrypted");
    } finally {
      dek?.fill(0);
    }
  }

  /** Stores (or replaces) the credential of one connection and audits `credential.stored`. */
  async put(tenantId: string, connectionId: string, secret: VaultSecret, meta: VaultMeta): Promise<void> {
    const sealed = await this.seal(tenantId, connectionId, secret);
    await withTenant(this.d.pool, brokerCtx(tenantId), async (tx) => {
      await this.write(tx, tenantId, connectionId, sealed, meta);
      await appendAudit(tx, {
        principalId: BROKER_PRINCIPAL, action: "credential.stored", subjectType: "connection", subjectId: connectionId,
        details: { connection_id: connectionId, key_provider: this.d.keys.name },
      });
    });
  }

  /** Writes the sealed row inside the caller's transaction (insert or replace). */
  async write(tx: Tx, tenantId: string, connectionId: string, sealed: SealedSecret, meta: VaultMeta): Promise<void> {
    await tx.query(
      `insert into credentials (tenant_id, connection_id, ciphertext, nonce, wrapped_dek, key_provider, key_ref, scopes, expires_at,
                                refresh_state, refresh_lease_until, last_refreshed_at, created_at)
       values ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'ok', null, null, $10)
       on conflict (tenant_id, connection_id) do update set
         ciphertext = excluded.ciphertext, nonce = excluded.nonce, wrapped_dek = excluded.wrapped_dek,
         key_provider = excluded.key_provider, key_ref = excluded.key_ref, scopes = excluded.scopes,
         expires_at = excluded.expires_at, refresh_state = 'ok', refresh_lease_until = null, rotated_at = $10`,
      [tenantId, connectionId, sealed.ciphertext, sealed.nonce, sealed.wrappedDek, this.d.keys.name, this.d.keys.keyRef, meta.scopes, meta.expiresAt, this.d.clock.now()],
    );
  }

  async readRow(tenantId: string, connectionId: string): Promise<CredentialRow | null> {
    return withTenant(this.d.pool, brokerCtx(tenantId), async (tx) => {
      const r = await tx.query<CredentialRow>(
        `select ciphertext, nonce, wrapped_dek, key_provider, key_ref, scopes, expires_at, refresh_state, refresh_lease_until, last_refreshed_at
         from credentials where tenant_id = $1 and connection_id = $2`,
        [tenantId, connectionId],
      );
      return r.rows[0] ?? null;
    });
  }

  /** Reads and decrypts one credential. `not_found` when there is none. */
  async get(tenantId: string, connectionId: string): Promise<{ secret: VaultSecret; meta: CredentialMeta }> {
    const row = await this.readRow(tenantId, connectionId);
    if (!row) throw new BrokerError("not_found", "no credential for this connection");
    return { secret: await this.openRow(tenantId, connectionId, row), meta: metaOf(row) };
  }

  /** Deletes the credential row (its data key goes with it) and audits `credential.shredded`. Idempotent. */
  async shred(tenantId: string, connectionId: string): Promise<boolean> {
    return withTenant(this.d.pool, brokerCtx(tenantId), async (tx) => {
      const r = await tx.query("delete from credentials where tenant_id = $1 and connection_id = $2", [tenantId, connectionId]);
      const removed = (r.rowCount ?? 0) > 0;
      if (removed) {
        await appendAudit(tx, {
          principalId: BROKER_PRINCIPAL, action: "credential.shredded", subjectType: "connection", subjectId: connectionId,
          details: { connection_id: connectionId },
        });
      }
      return removed;
    });
  }

  /** Deletes every credential row of the tenant (tenant delete). */
  async shredTenant(tenantId: string): Promise<number> {
    return withTenant(this.d.pool, brokerCtx(tenantId), async (tx) => {
      const r = await tx.query("delete from credentials where tenant_id = $1", [tenantId]);
      const n = r.rowCount ?? 0;
      if (n > 0) {
        await appendAudit(tx, {
          principalId: BROKER_PRINCIPAL, action: "credential.shredded", subjectType: "tenant", subjectId: tenantId,
          details: { rows: n },
        });
      }
      return n;
    });
  }
}
