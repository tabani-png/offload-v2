import { expect } from "bun:test";
import { randomBytes, createHash } from "node:crypto";
import { insertSession, uuidv7, withTenant } from "@offload/db";
import type { FixtureTenant } from "@offload/testkit";
import { envelope, objectId, type Harness, type Obj, type TestDevice } from "../m3-01-ingest-batches/harness.ts";

/** m3-05b helpers on top of the m3-01 harness (real Postgres, fake clock, signed batches). */

export const DAY_MS = 86_400_000;
const sha256Hex = (s: string) => createHash("sha256").update(s).digest("hex");

/** A device of `member` with upload consent. */
export async function consentingDevice(h: Harness, tenant: FixtureTenant, member: string): Promise<TestDevice> {
  const dev = await h.device(tenant, member);
  await h.consent(dev);
  return dev;
}

/** POST /v1/imports with a member token of `dev`; returns the response. */
export async function openImportRes(h: Harness, dev: TestDevice, body: unknown = { source_kind: "videos" }): Promise<Response> {
  return h.req("/v1/imports", { method: "POST", bearer: await h.token(dev, "member"), json: body });
}

/** Opens an import space and returns its id. */
export async function openImport(h: Harness, dev: TestDevice, sourceKind = "videos"): Promise<string> {
  const res = await openImportRes(h, dev, { source_kind: sourceKind });
  expect(res.status).toBe(201);
  const body = (await res.json()) as { import_id: string };
  return body.import_id;
}

export async function forgetRes(h: Harness, dev: TestDevice, body: unknown): Promise<Response> {
  return h.req("/v1/me/forget", { method: "POST", bearer: await h.token(dev, "member"), json: body });
}

export async function forgetImport(h: Harness, dev: TestDevice, importId: string): Promise<string> {
  const res = await forgetRes(h, dev, { scope: "import", import_id: importId });
  expect(res.status).toBe(202);
  return ((await res.json()) as { purge_request_id: string }).purge_request_id;
}

/** Imported observations: a focus and a text snapshot at `ts`, tagged with the import. */
export function imported(importId: string, ts: string): Obj[] {
  const text = "Invoice 2026 total due, step 2 of 3";
  return [
    { id: objectId(), ts, kind: "focus", app_bundle_id: "com.apple.Safari", app_name: "Safari", source: "import", import_id: importId },
    { id: objectId(), ts, kind: "text_snapshot", app_bundle_id: "com.apple.Safari", text_source: "ocr", text, text_hash: sha256Hex(text), source: "import", import_id: importId },
  ];
}

/** Next seq per device in this process. */
const seqs = new Map<string, number>();
export function nextSeq(dev: TestDevice): number {
  const n = (seqs.get(dev.deviceId) ?? 0) + 1;
  seqs.set(dev.deviceId, n);
  return n;
}

export async function ingestObjects(h: Harness, dev: TestDevice, objects: Obj[]) {
  return h.ingest(dev, envelope(h, dev, nextSeq(dev), objects));
}

/** Rows (RLS bypassed) in `table` with this import id. */
export async function rowsWithImport(h: Harness, table: "observations" | "observation_texts", importId: string): Promise<number> {
  return (await h.fx.admin.query(`select count(*)::int as n from ${table} where import_id = $1`, [importId])).rows[0].n as number;
}

export async function outboxWithImport(h: Harness, importId: string): Promise<number> {
  return (await h.fx.admin.query("select count(*)::int as n from events_outbox where payload->>'import_id' = $1", [importId])).rows[0].n as number;
}

/** A web session for `member` whose CSRF token is `csrf`: returns the cookie header value. */
export async function webSession(h: Harness, tenant: FixtureTenant, member: string, csrf: string): Promise<string> {
  const token = randomBytes(32).toString("base64url");
  const now = h.clock.now();
  await withTenant(h.fx.app, h.fx.ctx(tenant, member), (tx) =>
    insertSession(tx, {
      tenantId: tenant.tenantId, id: uuidv7(), memberId: member, tokenSha256: sha256Hex(token), csrfSha256: sha256Hex(csrf),
      now, expiresAt: new Date(now.getTime() + DAY_MS),
    }));
  return `__Host-offload_session=${token}`;
}
