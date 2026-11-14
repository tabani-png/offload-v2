import type { Tx } from "./tenancy.ts";

/**
 * Auth queries (m1-04-login-devices, ADR 0014). Tables from m1-03; no new migrations.
 * - Resolvers run before a tenant is known: they call the SECURITY DEFINER auth_resolve_* functions and take any
 *   queryable (a pool or a Tx from withTransaction).
 * - Everything else runs inside withTenant (RLS sets the tenant). Times come from the caller's clock, never now(),
 *   so expiry is decided by one clock.
 * Raw tokens never reach this module: callers pass sha256 hex.
 */

export interface Queryable {
  query: Tx["query"];
}

const one = <R>(rows: R[]): R | null => rows[0] ?? null;

export async function resolveIdentity(q: Queryable, idpSubject: string): Promise<{ tenantId: string; memberId: string } | null> {
  const r = one((await q.query("select tenant_id, member_id from auth_resolve_identity($1)", [idpSubject])).rows);
  return r ? { tenantId: r.tenant_id, memberId: r.member_id } : null;
}

export interface ResolvedSession {
  tenantId: string;
  memberId: string;
  tenantRole: "owner" | "admin" | "member" | "auditor";
  expiresAt: Date;
  lastSeenAt: Date;
}

export async function resolveSession(q: Queryable, tokenSha256: string): Promise<ResolvedSession | null> {
  const r = one((await q.query(
    "select tenant_id, member_id, tenant_role, expires_at, last_seen_at from auth_resolve_session($1)", [tokenSha256],
  )).rows);
  return r ? { tenantId: r.tenant_id, memberId: r.member_id, tenantRole: r.tenant_role, expiresAt: r.expires_at, lastSeenAt: r.last_seen_at } : null;
}

export async function resolveDevice(q: Queryable, deviceId: string): Promise<{ tenantId: string; memberId: string; revokedAt: Date | null } | null> {
  const r = one((await q.query("select tenant_id, member_id, revoked_at from auth_resolve_device($1::uuid)", [deviceId])).rows);
  return r ? { tenantId: r.tenant_id, memberId: r.member_id, revokedAt: r.revoked_at } : null;
}

export interface ResolvedEnrollmentCode {
  tenantId: string;
  memberId: string;
  codeChallenge: string;
  redirectUri: string;
  expiresAt: Date;
  usedAt: Date | null;
}

export async function resolveEnrollmentCode(q: Queryable, codeSha256: string): Promise<ResolvedEnrollmentCode | null> {
  const r = one((await q.query(
    "select tenant_id, member_id, code_challenge, redirect_uri, expires_at, used_at from auth_resolve_enrollment_code($1)", [codeSha256],
  )).rows);
  return r
    ? { tenantId: r.tenant_id, memberId: r.member_id, codeChallenge: r.code_challenge, redirectUri: r.redirect_uri, expiresAt: r.expires_at, usedAt: r.used_at }
    : null;
}

// ---- members and me (inside withTenant) ------------------------------------------------------------------------

export async function memberRole(tx: Tx, memberId: string): Promise<ResolvedSession["tenantRole"] | null> {
  return one((await tx.query("select tenant_role from members where id = $1 and state not in ('departed', 'frozen')", [memberId])).rows)?.tenant_role ?? null;
}

export interface MeRows {
  member: { id: string; email: string; display_name: string | null; tenant_role: ResolvedSession["tenantRole"]; state: string };
  tenant: { id: string; kind: "personal" | "team"; name: string; plan: "free" | "pro" | "enterprise"; reporting_timezone: string };
  workspaces: { id: string; name: string; workspace_role: "lead" | "member" }[];
}

export async function loadMe(tx: Tx, memberId: string): Promise<MeRows | null> {
  const member = one((await tx.query("select id, email, display_name, tenant_role, state from members where id = $1", [memberId])).rows);
  if (!member) return null;
  const tenant = one((await tx.query(
    "select id, kind, name, plan, reporting_timezone from tenants where deleted_at is null",
  )).rows);
  if (!tenant) return null;
  const workspaces = (await tx.query(
    `select w.id, w.name, wm.workspace_role from workspace_members wm
     join workspaces w on w.tenant_id = wm.tenant_id and w.id = wm.workspace_id
     where wm.member_id = $1 and w.archived_at is null order by w.created_at, w.id`,
    [memberId],
  )).rows;
  return { member, tenant, workspaces };
}

// ---- web sessions -----------------------------------------------------------------------------------------------

export async function insertSession(tx: Tx, s: {
  tenantId: string; id: string; memberId: string; tokenSha256: string; csrfSha256: string; now: Date; expiresAt: Date;
}): Promise<void> {
  await tx.query(
    `insert into sessions (tenant_id, id, member_id, token_sha256, csrf_sha256, created_at, last_seen_at, expires_at)
     values ($1, $2, $3, $4, $5, $6, $6, $7)`,
    [s.tenantId, s.id, s.memberId, s.tokenSha256, s.csrfSha256, s.now, s.expiresAt],
  );
}

/** Marks the session seen at `now` and returns its id and csrf hash; null when it is gone or revoked. */
export async function touchSession(tx: Tx, tokenSha256: string, now: Date): Promise<{ id: string; csrfSha256: string } | null> {
  const r = one((await tx.query(
    "update sessions set last_seen_at = greatest(last_seen_at, $2) where token_sha256 = $1 and revoked_at is null returning id, csrf_sha256",
    [tokenSha256, now],
  )).rows);
  return r ? { id: r.id, csrfSha256: r.csrf_sha256 } : null;
}

/** Swaps the "not yet issued" csrf hash for the issued one; true only for the first caller. */
export async function issueCsrfOnce(tx: Tx, sessionId: string, unissuedSha256: string, csrfSha256: string): Promise<boolean> {
  const r = await tx.query("update sessions set csrf_sha256 = $3 where id = $1 and csrf_sha256 = $2 and revoked_at is null", [sessionId, unissuedSha256, csrfSha256]);
  return (r.rowCount ?? 0) === 1;
}

export async function revokeSession(tx: Tx, tokenSha256: string, now: Date): Promise<string | null> {
  return one((await tx.query(
    "update sessions set revoked_at = $2 where token_sha256 = $1 and revoked_at is null returning id", [tokenSha256, now],
  )).rows)?.id ?? null;
}

// ---- magic links (global table, no tenant) ---------------------------------------------------------------------

export async function insertMagicLink(q: Queryable, m: { tokenSha256: string; emailHash: string; returnTo: string; expiresAt: Date }): Promise<void> {
  await q.query("insert into magic_links (token_sha256, email_hash, return_to, expires_at) values ($1, $2, $3, $4)",
    [m.tokenSha256, m.emailHash, m.returnTo, m.expiresAt]);
}

export type MagicLinkClaim = { status: "ok"; emailHash: string; returnTo: string } | { status: "expired" } | { status: "unknown" };

/** Single use: the first claim before expiry wins; a used or unknown token is "unknown". */
export async function claimMagicLink(q: Queryable, tokenSha256: string, now: Date): Promise<MagicLinkClaim> {
  const r = one((await q.query(
    "update magic_links set used_at = $2 where token_sha256 = $1 and used_at is null and expires_at > $2 returning email_hash, return_to",
    [tokenSha256, now],
  )).rows);
  if (r) return { status: "ok", emailHash: r.email_hash, returnTo: r.return_to };
  const left = one((await q.query("select used_at from magic_links where token_sha256 = $1", [tokenSha256])).rows);
  return left && left.used_at === null ? { status: "expired" } : { status: "unknown" };
}

// ---- device enrollment -----------------------------------------------------------------------------------------

export async function insertEnrollmentCode(tx: Tx, c: {
  tenantId: string; codeSha256: string; memberId: string; codeChallenge: string; redirectUri: string; expiresAt: Date;
}): Promise<void> {
  await tx.query(
    `insert into device_enrollment_codes (tenant_id, code_sha256, member_id, code_challenge, redirect_uri, expires_at)
     values ($1, $2, $3, $4, $5, $6)`,
    [c.tenantId, c.codeSha256, c.memberId, c.codeChallenge, c.redirectUri, c.expiresAt],
  );
}

/** Single use: true only for the first claim before expiry. */
export async function claimEnrollmentCode(tx: Tx, codeSha256: string, now: Date): Promise<boolean> {
  const r = await tx.query(
    "update device_enrollment_codes set used_at = $2 where code_sha256 = $1 and used_at is null and expires_at > $2", [codeSha256, now],
  );
  return (r.rowCount ?? 0) === 1;
}

export interface DeviceRow {
  id: string;
  member_id: string;
  name: string;
  key_storage: "secure_enclave" | "keychain";
  enrolled_at: Date;
  revoked_at: Date | null;
}

export async function insertDevice(tx: Tx, d: {
  tenantId: string; id: string; memberId: string; publicJwk: Record<string, string>; keyStorage: string; name: string; now: Date;
}): Promise<void> {
  await tx.query(
    `insert into devices (tenant_id, id, member_id, public_jwk, key_storage, name, enrolled_at)
     values ($1, $2, $3, $4, $5, $6, $7)`,
    [d.tenantId, d.id, d.memberId, JSON.stringify(d.publicJwk), d.keyStorage, d.name, d.now],
  );
}

/** A member's own devices, or every device in the tenant when `memberId` is null (owner and admin). */
export async function listDevices(tx: Tx, memberId: string | null): Promise<DeviceRow[]> {
  return (await tx.query(
    `select id, member_id, name, key_storage, enrolled_at, revoked_at from devices
     where ($1::uuid is null or member_id = $1::uuid) order by enrolled_at, id`,
    [memberId],
  )).rows;
}

export async function getDevice(tx: Tx, deviceId: string): Promise<(DeviceRow & { public_jwk: Record<string, string> }) | null> {
  return one((await tx.query(
    "select id, member_id, name, key_storage, enrolled_at, revoked_at, public_jwk from devices where id = $1", [deviceId],
  )).rows);
}

/** Sets revoked_at once; true when this call revoked it. */
export async function revokeDevice(tx: Tx, deviceId: string, now: Date): Promise<boolean> {
  const r = await tx.query("update devices set revoked_at = $2 where id = $1 and revoked_at is null", [deviceId, now]);
  return (r.rowCount ?? 0) === 1;
}

// ---- device nonces ---------------------------------------------------------------------------------------------

export async function insertNonce(tx: Tx, n: { tenantId: string; deviceId: string; nonce: string; audience: "device" | "member"; expiresAt: Date }): Promise<void> {
  await tx.query("insert into device_nonces (tenant_id, device_id, nonce, audience, expires_at) values ($1, $2, $3, $4, $5)",
    [n.tenantId, n.deviceId, n.nonce, n.audience, n.expiresAt]);
}

export async function getNonce(tx: Tx, deviceId: string, nonce: string): Promise<{ audience: "device" | "member"; expiresAt: Date; usedAt: Date | null } | null> {
  const r = one((await tx.query("select audience, expires_at, used_at from device_nonces where device_id = $1 and nonce = $2", [deviceId, nonce])).rows);
  return r ? { audience: r.audience, expiresAt: r.expires_at, usedAt: r.used_at } : null;
}

/** Single use: true only for the first claim before expiry. */
export async function claimNonce(tx: Tx, deviceId: string, nonce: string, now: Date): Promise<boolean> {
  const r = await tx.query(
    "update device_nonces set used_at = $3 where device_id = $1 and nonce = $2 and used_at is null and expires_at > $3", [deviceId, nonce, now],
  );
  return (r.rowCount ?? 0) === 1;
}

/** Unused, unexpired nonces of a device (the challenge endpoint caps them). */
export async function countOpenNonces(tx: Tx, deviceId: string, now: Date): Promise<number> {
  return (await tx.query<{ n: number }>(
    "select count(*)::int as n from device_nonces where device_id = $1 and used_at is null and expires_at > $2", [deviceId, now],
  )).rows[0]!.n;
}
