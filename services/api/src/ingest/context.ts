import type { Context } from "hono";
import type { Pool } from "pg";
import { memberRole, resolveDevice, withTenant, type TenantContext } from "@offload/db";
import type { Clock } from "../clock.ts";
import type { DeviceTokenIssuer } from "../auth/device-token.ts";
import { ApiError, unauthenticated } from "../http.ts";

/** What the ingest module needs from the app: the pool, the clock, the token issuer and member authentication. */
export interface IngestDeps {
  /** Pool connected as offload_app. */
  pool: Pool;
  clock: Clock;
  tokens: DeviceTokenIssuer;
  /** Member token or web session (with CSRF on mutations), as GET /v1/me uses. */
  authenticateMember(c: Context): Promise<{ tenantId: string; memberId: string; tenantRole: "owner" | "admin" | "member" | "auditor" }>;
}

/** A verified device token: whose device it is and the transaction context for its member. */
export interface DevicePrincipal {
  tenantId: string;
  memberId: string;
  deviceId: string;
  ctx: TenantContext;
}

/**
 * Device token (Authorization: Bearer, audience `device`) for a device that is not revoked, whose member is active.
 * A valid signature alone is not enough: the device row is checked on every request (ADR 0014).
 */
export async function authenticateDevice(c: Context, deps: IngestDeps): Promise<DevicePrincipal> {
  const authz = c.req.header("authorization");
  const m = authz === undefined ? null : /^Bearer ([A-Za-z0-9_.-]{1,4096})$/.exec(authz);
  if (!m) throw unauthenticated();
  const v = await deps.tokens.verify(m[1]!, "device");
  if (!v.ok) throw new ApiError(401, v.code, v.code === "token_expired" ? "token expired" : "not a device token");
  const d = await resolveDevice(deps.pool, v.claims.device_id);
  if (!d || d.revokedAt !== null || d.tenantId !== v.claims.tenant_id || d.memberId !== v.claims.member_id) throw unauthenticated("device revoked");
  const role = await withTenant(deps.pool, { tenantId: d.tenantId, principalId: d.memberId, memberId: d.memberId, tenantRole: "member" }, (tx) => memberRole(tx, d.memberId));
  if (!role) throw unauthenticated();
  const deviceId = v.claims.device_id;
  return { tenantId: d.tenantId, memberId: d.memberId, deviceId, ctx: { tenantId: d.tenantId, principalId: deviceId, memberId: d.memberId, tenantRole: role } };
}

export interface RateLimiter {
  /** Counts one request for `key`; throws 429 rate_limited with Retry-After when the window is full. */
  hit(key: string): void;
}

/** Sliding window kept in memory per process: `limit` requests per `windowMs` per key. Refused requests do not count. */
export function createRateLimiter(opts: { limit: number; windowMs: number; clock: Clock }): RateLimiter {
  const seen = new Map<string, number[]>();
  return {
    hit(key) {
      const now = opts.clock.now().getTime();
      const recent = (seen.get(key) ?? []).filter((t) => t > now - opts.windowMs);
      if (recent.length >= opts.limit) {
        seen.set(key, recent);
        const err = new ApiError(429, "rate_limited", "too many requests");
        err.retryAfterSeconds = Math.max(1, Math.ceil((recent[0]! + opts.windowMs - now) / 1000));
        throw err;
      }
      recent.push(now);
      seen.set(key, recent);
    },
  };
}
