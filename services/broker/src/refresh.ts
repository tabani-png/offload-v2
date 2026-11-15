import type { Pool } from "pg";
import { appendAudit, withTenant } from "@offload/db";
import { BrokerError } from "./errors.ts";
import { postForm } from "./egress/http.ts";
import type { OAuthConfig } from "./egress/hosts.ts";
import type { Logger } from "./log.ts";
import { BROKER_PRINCIPAL, brokerCtx, metaOf, type CredentialRow, type Vault } from "./vault/vault.ts";

/**
 * Single-flight token refresh (ADR 0034). A short transaction takes a 30 s lease only if no live lease exists; the
 * provider call runs outside any transaction; a second short transaction writes the new token and clears the lease.
 * Callers that find a live lease wait for it (bounded) and re-read.
 */

export const LEASE_MS = 30_000;

export interface RefreshDeps {
  pool: Pool;
  vault: Vault;
  clock: { now(): Date };
  logger: Logger;
  /** How long a caller waits for another caller's lease before giving up, in ms. */
  leaseWaitMs: number;
  /** Looks up the OAuth config of the connection's provider; null when the connection has none. */
  oauthFor(tenantId: string, connectionId: string): Promise<OAuthConfig | null>;
}

export type RefreshResult = "refreshed" | "fresh";

const COLUMNS = "ciphertext, nonce, wrapped_dek, key_provider, key_ref, scopes, expires_at, refresh_state, refresh_lease_until, last_refreshed_at";

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export function createRefresher(d: RefreshDeps) {
  async function tryClaim(tenantId: string, connectionId: string, staleBefore: Date | null): Promise<CredentialRow | null> {
    const now = d.clock.now();
    return withTenant(d.pool, brokerCtx(tenantId), async (tx) => {
      const r = await tx.query<CredentialRow>(
        `update credentials set refresh_state = 'refreshing', refresh_lease_until = $3
         where tenant_id = $1 and connection_id = $2 and refresh_state in ('ok', 'refreshing')
           and (refresh_lease_until is null or refresh_lease_until <= $4)
           and ($5::timestamptz is null or expires_at is null or expires_at <= $5)
         returning ${COLUMNS}`,
        [tenantId, connectionId, new Date(now.getTime() + LEASE_MS), now, staleBefore],
      );
      return r.rows[0] ?? null;
    });
  }

  async function release(tenantId: string, connectionId: string): Promise<void> {
    await withTenant(d.pool, brokerCtx(tenantId), (tx) =>
      tx.query(
        "update credentials set refresh_state = 'ok', refresh_lease_until = null where tenant_id = $1 and connection_id = $2 and refresh_state = 'refreshing'",
        [tenantId, connectionId],
      ),
    );
  }

  async function markFailed(tenantId: string, connectionId: string): Promise<void> {
    await withTenant(d.pool, brokerCtx(tenantId), async (tx) => {
      await tx.query(
        "update credentials set refresh_state = 'failed', refresh_lease_until = null where tenant_id = $1 and connection_id = $2",
        [tenantId, connectionId],
      );
      await tx.query("update connections set state = 'needs_reauth' where tenant_id = $1 and id = $2", [tenantId, connectionId]);
      await appendAudit(tx, {
        principalId: BROKER_PRINCIPAL, action: "credential.refreshed", subjectType: "connection", subjectId: connectionId,
        details: { connection_id: connectionId, outcome: "refused" },
      });
    });
  }

  /** The caller holds the lease on `row`: run the provider call outside any transaction, then write the result. */
  async function runRefresh(tenantId: string, connectionId: string, row: CredentialRow): Promise<void> {
    const oauth = await d.oauthFor(tenantId, connectionId).catch(async (e: unknown) => {
      await release(tenantId, connectionId);
      throw e;
    });
    let secret;
    try {
      secret = await d.vault.openRow(tenantId, connectionId, row);
    } catch (e) {
      await release(tenantId, connectionId);
      throw e;
    }
    if (!oauth || secret.kind !== "oauth" || !secret.refresh_token) {
      await markFailed(tenantId, connectionId);
      throw new BrokerError("state_conflict", "the credential cannot be refreshed: reconnect the app");
    }
    let res: Awaited<ReturnType<typeof postForm>>;
    try {
      res = await postForm(oauth.tokenUrl, {
        grant_type: "refresh_token", refresh_token: secret.refresh_token, client_id: oauth.clientId, client_secret: oauth.clientSecret,
      });
    } catch (e) {
      await release(tenantId, connectionId);
      throw e;
    }
    const access = res.json?.["access_token"];
    if (res.status >= 200 && res.status < 300 && typeof access === "string" && access !== "") {
      const newRefresh = res.json?.["refresh_token"];
      const expiresIn = res.json?.["expires_in"];
      const now = d.clock.now();
      const expiresAt = typeof expiresIn === "number" && expiresIn > 0 ? new Date(now.getTime() + expiresIn * 1000) : null;
      const sealed = await d.vault.seal(tenantId, connectionId, {
        kind: "oauth", access_token: access, refresh_token: typeof newRefresh === "string" && newRefresh !== "" ? newRefresh : secret.refresh_token,
      }).catch(async (e: unknown) => {
        await release(tenantId, connectionId);
        throw e;
      });
      const wrote = await withTenant(d.pool, brokerCtx(tenantId), async (tx) => {
        const u = await tx.query(
          `update credentials set ciphertext = $3, nonce = $4, wrapped_dek = $5, key_provider = $6, key_ref = $7, expires_at = $8,
             refresh_state = 'ok', refresh_lease_until = null, last_refreshed_at = $9, rotated_at = $9
           where tenant_id = $1 and connection_id = $2 and refresh_state = 'refreshing'`,
          [tenantId, connectionId, sealed.ciphertext, sealed.nonce, sealed.wrappedDek, row.key_provider, row.key_ref, expiresAt, now],
        );
        if ((u.rowCount ?? 0) === 0) return false; // shredded or changed while the call ran
        await appendAudit(tx, {
          principalId: BROKER_PRINCIPAL, action: "credential.refreshed", subjectType: "connection", subjectId: connectionId,
          details: { connection_id: connectionId, outcome: "ok" },
        });
        return true;
      });
      if (!wrote) throw new BrokerError("not_found", "the credential changed during the refresh");
      return;
    }
    if (res.status === 400 || res.status === 401) {
      d.logger.warn("refresh.refused", { tenant_id: tenantId, connection_id: connectionId, status: res.status });
      await markFailed(tenantId, connectionId);
      throw new BrokerError("state_conflict", "the provider refused the refresh: reconnect the app");
    }
    await release(tenantId, connectionId);
    throw new BrokerError("upstream_unreachable", "the provider could not refresh the token");
  }

  /**
   * Refreshes the connection's token. With `staleBefore`, does nothing when the token does not expire before that
   * instant. Returns "refreshed" when this call made the provider call and "fresh" when another caller did or none was needed.
   */
  return async function refresh(tenantId: string, connectionId: string, opts: { staleBefore?: Date } = {}): Promise<RefreshResult> {
    const deadline = Date.now() + d.leaseWaitMs;
    let claimNow = true;
    let waited = false;
    for (;;) {
      if (claimNow) {
        const claimed = await tryClaim(tenantId, connectionId, opts.staleBefore ?? null);
        if (claimed) {
          await runRefresh(tenantId, connectionId, claimed);
          return "refreshed";
        }
      }
      const row = await d.vault.readRow(tenantId, connectionId);
      if (!row) throw new BrokerError("not_found", "no credential for this connection");
      const m = metaOf(row);
      if (m.refreshState === "failed" || m.refreshState === "revoked") throw new BrokerError("state_conflict", "the credential needs re-authorization");
      const live = m.refreshState === "refreshing" && m.refreshLeaseUntil !== null && m.refreshLeaseUntil.getTime() > d.clock.now().getTime();
      if (live) {
        if (Date.now() >= deadline) throw new BrokerError("state_conflict", "another refresh of this credential is in progress");
        await sleep(10);
        claimNow = false;
        waited = true;
        continue;
      }
      // The holder we waited for crashed: its lease ran out without a result, so take the lease ourselves.
      if (waited && m.refreshState === "refreshing") {
        waited = false;
        claimNow = true;
        continue;
      }
      // Nobody holds the lease: the holder we waited for finished, or the token is not stale.
      return "fresh";
    }
  };
}
