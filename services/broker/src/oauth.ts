import { createHash, randomBytes } from "node:crypto";
import type { Pool } from "pg";
import { sha256Hex } from "@offload/contracts";
import type { OAuthBeginRequest, OAuthFinishRequest } from "@offload/contracts/src/broker/index.ts";
import { appendAudit, withTenant } from "@offload/db";
import { BrokerError } from "./errors.ts";
import { getJson, postForm } from "./egress/http.ts";
import type { ProviderTable } from "./egress/hosts.ts";
import type { Logger } from "./log.ts";
import { BROKER_PRINCIPAL, brokerCtx, type Vault } from "./vault/vault.ts";

/**
 * OAuth code flow with PKCE S256 (ADR 0034). `begin` stores only the sha256 of `state` and the verifier; `finish`
 * claims the state once, exchanges the code with the client secret inside this process, and puts the tokens straight
 * into the vault. The provider call runs outside any transaction.
 */

export const OAUTH_REQUEST_TTL_MS = 10 * 60_000;

export interface OAuthDeps {
  pool: Pool;
  vault: Vault;
  providers: ProviderTable;
  clock: { now(): Date };
  logger: Logger;
}

export function createOAuth(d: OAuthDeps) {
  async function begin(req: OAuthBeginRequest): Promise<{ authorize_url: string }> {
    const cfg = d.providers[req.provider]?.oauth;
    if (!cfg) throw new BrokerError("invalid_request", "this provider has no OAuth client");
    const state = randomBytes(32).toString("base64url");
    const verifier = randomBytes(32).toString("base64url");
    const challenge = createHash("sha256").update(verifier).digest("base64url");
    const now = d.clock.now();
    await withTenant(d.pool, brokerCtx(req.tenant_id), async (tx) => {
      const c = await tx.query<{ provider: string }>("select provider from connections where tenant_id = $1 and id = $2", [req.tenant_id, req.connection_id]);
      if (!c.rows[0]) throw new BrokerError("not_found", "connection not found");
      if (c.rows[0].provider !== req.provider) throw new BrokerError("invalid_request", "provider does not match the connection");
      try {
        await tx.query(
          `insert into oauth_requests (tenant_id, state_sha256, connection_id, member_id, provider, code_verifier, redirect_uri, created_at, expires_at)
           values ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
          [req.tenant_id, sha256Hex(state), req.connection_id, req.member_id, req.provider, verifier, req.redirect_uri, now, new Date(now.getTime() + OAUTH_REQUEST_TTL_MS)],
        );
      } catch (e) {
        if ((e as { code?: string }).code === "23503") throw new BrokerError("invalid_request", "member not found"); // foreign key: no such member
        throw e;
      }
    });
    const u = new URL(cfg.authorizeUrl);
    for (const [k, v] of Object.entries(cfg.extraAuthorizeParams ?? {})) u.searchParams.set(k, v);
    u.searchParams.set("response_type", "code");
    u.searchParams.set("client_id", cfg.clientId);
    u.searchParams.set("redirect_uri", req.redirect_uri);
    u.searchParams.set("scope", req.scopes.join(" "));
    u.searchParams.set("state", state);
    u.searchParams.set("code_challenge", challenge);
    u.searchParams.set("code_challenge_method", "S256");
    return { authorize_url: u.toString() };
  }

  async function finish(req: OAuthFinishRequest) {
    const now = d.clock.now();
    const claimed = await withTenant(d.pool, brokerCtx(req.tenant_id), async (tx) => {
      const r = await tx.query<{ connection_id: string; provider: string; code_verifier: string; redirect_uri: string }>(
        `update oauth_requests set used_at = $3
         where tenant_id = $1 and state_sha256 = $2 and used_at is null and expires_at > $3
         returning connection_id, provider, code_verifier, redirect_uri`,
        [req.tenant_id, sha256Hex(req.state), now],
      );
      return r.rows[0] ?? null;
    });
    if (!claimed) throw new BrokerError("invalid_request", "the authorization state is unknown, used or expired");
    const cfg = d.providers[claimed.provider]?.oauth;
    if (!cfg) throw new BrokerError("invalid_request", "this provider has no OAuth client");

    const token = await postForm(cfg.tokenUrl, {
      grant_type: "authorization_code", code: req.code, client_id: cfg.clientId, client_secret: cfg.clientSecret,
      code_verifier: claimed.code_verifier, redirect_uri: claimed.redirect_uri,
    });
    const access = token.json?.["access_token"];
    if (token.status < 200 || token.status >= 300 || typeof access !== "string" || access === "") {
      d.logger.warn("oauth.exchange_failed", { tenant_id: req.tenant_id, connection_id: claimed.connection_id, status: token.status });
      throw new BrokerError("oauth_exchange_failed", "the provider refused the authorization code");
    }
    const refresh = token.json?.["refresh_token"];
    const expiresIn = token.json?.["expires_in"];
    const scopeText = token.json?.["scope"];
    const scopes = typeof scopeText === "string" ? scopeText.split(/\s+/).filter((s) => s !== "") : [];

    const info = await getJson(cfg.userinfoUrl, access);
    const sub = info.json?.["sub"];
    if (info.status < 200 || info.status >= 300 || (typeof sub !== "string" && typeof sub !== "number")) {
      throw new BrokerError("oauth_exchange_failed", "the provider did not identify the account");
    }
    const email = info.json?.["email"];
    const accountLabel = (typeof email === "string" && email !== "" ? email : String(sub)).slice(0, 256);
    const accountHash = sha256Hex(String(sub));

    const expiresAt = typeof expiresIn === "number" && expiresIn > 0 ? new Date(d.clock.now().getTime() + expiresIn * 1000) : null;
    const sealed = await d.vault.seal(req.tenant_id, claimed.connection_id, {
      kind: "oauth", access_token: access, ...(typeof refresh === "string" && refresh !== "" ? { refresh_token: refresh } : {}),
    });
    await withTenant(d.pool, brokerCtx(req.tenant_id), async (tx) => {
      await d.vault.write(tx, req.tenant_id, claimed.connection_id, sealed, { scopes, expiresAt });
      await tx.query("update connections set state = 'active' where tenant_id = $1 and id = $2", [req.tenant_id, claimed.connection_id]);
      await appendAudit(tx, {
        principalId: BROKER_PRINCIPAL, action: "credential.stored", subjectType: "connection", subjectId: claimed.connection_id,
        details: { connection_id: claimed.connection_id, account_hash: accountHash },
      });
    });
    return { connection_id: claimed.connection_id, account_label: accountLabel, account_hash: accountHash, scopes };
  }

  return { begin, finish };
}
