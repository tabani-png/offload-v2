import type { Context, Hono } from "hono";
import { UPLOAD_NOTICE_ID, UPLOAD_NOTICE_VERSION, appendAudit, uuidv7, withTenant, type Tx } from "@offload/db";
import { ApiError, invalidRequest } from "../http.ts";
import type { IngestDeps } from "./context.ts";

/**
 * Upload consent for the notice "what leaves your Mac" (docs/API.md "Auth and me", ONBOARDING screen 5). Ingest
 * accepts a member's observations only while a consent row for the current notice version is open.
 */

export interface UploadConsentState {
  notice_id: string;
  current_version: string;
  consented_version: string | null;
  needed: boolean;
}

/** The `upload_consent` field of GET /v1/me. Runs inside the member's withTenant. */
export async function uploadConsentState(tx: Tx, memberId: string): Promise<UploadConsentState> {
  const r = await tx.query<{ notice_version: string }>(
    "select notice_version from consents where member_id = $1 and notice_id = $2 and withdrawn_at is null",
    [memberId, UPLOAD_NOTICE_ID],
  );
  const consented = r.rows[0]?.notice_version ?? null;
  return { notice_id: UPLOAD_NOTICE_ID, current_version: UPLOAD_NOTICE_VERSION, consented_version: consented, needed: consented !== UPLOAD_NOTICE_VERSION };
}

/** True when the member has an open consent for the current notice version. */
export async function hasUploadConsent(tx: Tx, memberId: string): Promise<boolean> {
  const r = await tx.query(
    "select 1 from consents where member_id = $1 and notice_id = $2 and notice_version = $3 and withdrawn_at is null",
    [memberId, UPLOAD_NOTICE_ID, UPLOAD_NOTICE_VERSION],
  );
  return r.rows.length > 0;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

async function jsonObject(c: Context): Promise<Record<string, unknown>> {
  const type = (c.req.header("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
  if (type !== "application/json") throw invalidRequest("content-type must be application/json");
  let v: unknown;
  try {
    v = JSON.parse(await c.req.text());
  } catch {
    throw invalidRequest("body is not JSON");
  }
  if (typeof v !== "object" || v === null || Array.isArray(v)) throw invalidRequest("body must be an object");
  return v as Record<string, unknown>;
}

export function registerConsentRoutes(app: Hono, deps: IngestDeps): void {
  app.post("/v1/me/consents", async (c) => {
    const p = await deps.authenticateMember(c);
    const body = await jsonObject(c);
    const keys = Object.keys(body).sort().join(",");
    const { notice_id: noticeId, notice_version: noticeVersion, device_id: deviceId } = body;
    if (keys !== "device_id,notice_id,notice_version" || typeof noticeId !== "string" || typeof noticeVersion !== "string" || typeof deviceId !== "string") {
      throw invalidRequest("notice_id, notice_version and device_id are required");
    }
    if (noticeId !== UPLOAD_NOTICE_ID) throw invalidRequest("unknown notice_id");
    if (!/^[A-Za-z0-9_.-]{1,32}$/.test(noticeVersion)) throw invalidRequest("notice_version is a code");
    if (!UUID_RE.test(deviceId)) throw invalidRequest("device_id must be a uuid");
    if (noticeVersion !== UPLOAD_NOTICE_VERSION) throw new ApiError(409, "stale_notice", "the notice changed; show the current version");
    const ctx = { tenantId: p.tenantId, principalId: p.memberId, memberId: p.memberId, tenantRole: p.tenantRole };
    const now = deps.clock.now();
    const row = await withTenant(deps.pool, ctx, async (tx) => {
      const dev = (await tx.query("select 1 from devices where id = $1 and member_id = $2 and revoked_at is null", [deviceId, p.memberId])).rows[0];
      if (!dev) throw invalidRequest("device_id is not one of your devices");
      const open = (await tx.query<{ id: string; device_id: string; notice_version: string; given_at: Date }>(
        "select id, device_id, notice_version, given_at from consents where member_id = $1 and notice_id = $2 and withdrawn_at is null for update",
        [p.memberId, UPLOAD_NOTICE_ID],
      )).rows[0];
      // Giving the same consent twice is the same consent.
      if (open && open.notice_version === noticeVersion) return open;
      if (open) await tx.query("update consents set withdrawn_at = $2 where tenant_id = $1 and id = $3", [p.tenantId, now, open.id]);
      const id = uuidv7();
      await tx.query(
        "insert into consents (tenant_id, id, member_id, device_id, notice_id, notice_version, given_at) values ($1, $2, $3, $4, $5, $6, $7)",
        [p.tenantId, id, p.memberId, deviceId, UPLOAD_NOTICE_ID, noticeVersion, now],
      );
      await appendAudit(tx, {
        principalId: p.memberId, action: "privacy.consent_given", subjectType: "consent", subjectId: id,
        details: { notice_id: UPLOAD_NOTICE_ID, notice_version: noticeVersion, device_id: deviceId },
      });
      return { id, device_id: deviceId, notice_version: noticeVersion, given_at: now };
    });
    c.header("cache-control", "no-store");
    return c.json({
      id: row.id, notice_id: UPLOAD_NOTICE_ID, notice_version: row.notice_version, device_id: row.device_id,
      given_at: row.given_at.toISOString(), withdrawn_at: null,
    }, 201);
  });

  app.delete("/v1/me/consents/what-leaves-your-mac", async (c) => {
    const p = await deps.authenticateMember(c);
    const ctx = { tenantId: p.tenantId, principalId: p.memberId, memberId: p.memberId, tenantRole: p.tenantRole };
    await withTenant(deps.pool, ctx, async (tx) => {
      const r = await tx.query<{ id: string; notice_version: string }>(
        "update consents set withdrawn_at = $3 where tenant_id = $1 and member_id = $2 and notice_id = $4 and withdrawn_at is null returning id, notice_version",
        [p.tenantId, p.memberId, deps.clock.now(), UPLOAD_NOTICE_ID],
      );
      for (const row of r.rows) {
        await appendAudit(tx, {
          principalId: p.memberId, action: "privacy.consent_withdrawn", subjectType: "consent", subjectId: row.id,
          details: { notice_id: UPLOAD_NOTICE_ID, notice_version: row.notice_version },
        });
      }
    });
    return c.body(null, 204);
  });
}
