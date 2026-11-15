import { expect } from "bun:test";
import { jcs, sha256Hex } from "@offload/contracts";
import { uuidv7, ulid, withTenant } from "@offload/db";
import { FakeClock, deviceKey, deviceTokenSigningKey, pgTenantFixture, type DeviceKey, type FixtureTenant, type PgTenantFixture } from "@offload/testkit";
import { createApp } from "../../src/index.ts";

/** Shared setup for the m3-01 suite: real Postgres, a fake clock, devices with real P-256 keys, signed batches. */

export const BASE = "https://offload.test";
export const START = "2026-11-14T09:00:00.000Z";

export interface TestDevice {
  tenant: FixtureTenant;
  memberId: string;
  deviceId: string;
  key: DeviceKey;
}

export interface Harness {
  fx: PgTenantFixture;
  clock: FakeClock;
  /** A new app process on the same database (the restart tests). */
  newApp(): ReturnType<typeof createApp>;
  device(tenant: FixtureTenant, memberId: string): Promise<TestDevice>;
  token(dev: TestDevice, audience: "device" | "member"): Promise<string>;
  req(path: string, init?: RequestInit & { bearer?: string; json?: unknown; app?: ReturnType<typeof createApp> }): Promise<Response>;
  /** Signs `envelope` (JCS bytes) with the device key and posts it. */
  ingest(dev: TestDevice, envelope: unknown, opts?: IngestOpts): Promise<Response>;
  /** Gives the device's member upload consent for the current notice version. */
  consent(dev: TestDevice): Promise<Response>;
  /** Row counts as the database administrator sees them (RLS bypassed). */
  count(table: string, dev: TestDevice): Promise<number>;
  close(): Promise<void>;
}

export interface IngestOpts {
  bearer?: string;
  rawBody?: string;
  sig?: string;
  keyid?: string;
  app?: ReturnType<typeof createApp>;
  /** Sign with this key instead of the device's. */
  signWith?: DeviceKey;
}

export async function makeHarness(): Promise<Harness> {
  const fx = await pgTenantFixture();
  const clock = new FakeClock(START);
  const signingKey = deviceTokenSigningKey();
  const newApp = () => createApp({ pool: fx.app, publicBaseUrl: BASE, clock, deviceTokenSigningKeyPem: signingKey.pkcs8Pem });
  const defaultApp = newApp();
  const tokens = new Map<string, string>();

  const h: Harness = {
    fx, clock, newApp,
    async device(tenant, memberId) {
      const key = await deviceKey();
      const deviceId = uuidv7();
      await withTenant(fx.app, fx.ctx(tenant, memberId), (tx) =>
        tx.query(
          "insert into devices (tenant_id, id, member_id, public_jwk, key_storage, name) values ($1, $2, $3, $4, 'secure_enclave', 'Test Mac')",
          [tenant.tenantId, deviceId, memberId, JSON.stringify(key.publicJwk)],
        ));
      return { tenant, memberId, deviceId, key };
    },
    async token(dev, audience) {
      const cacheKey = `${dev.deviceId}:${audience}:${Math.floor(clock.now().getTime() / 600_000)}`;
      const cached = tokens.get(cacheKey);
      if (cached) return cached;
      const c = await defaultApp.request(`${BASE}/v1/devices/challenge`, {
        method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ device_id: dev.deviceId, audience }),
      });
      expect(c.status).toBe(200);
      const { nonce } = (await c.json()) as { nonce: string };
      const t = await defaultApp.request(`${BASE}/v1/devices/token`, {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ device_id: dev.deviceId, nonce, signature: await dev.key.sign(nonce) }),
      });
      expect(t.status).toBe(200);
      const { token } = (await t.json()) as { token: string };
      tokens.set(cacheKey, token);
      return token;
    },
    async req(path, init = {}) {
      const { bearer, json, app, ...rest } = init;
      const headers = new Headers(rest.headers);
      if (bearer) headers.set("authorization", `Bearer ${bearer}`);
      let body = rest.body;
      if (json !== undefined) {
        headers.set("content-type", "application/json");
        body = JSON.stringify(json);
      }
      return (app ?? defaultApp).request(`${BASE}${path}`, { ...rest, headers, body: body ?? null });
    },
    async ingest(dev, envelope, opts = {}) {
      const raw = opts.rawBody ?? jcs(envelope);
      const sig = opts.sig ?? (await (opts.signWith ?? dev.key).sign(raw));
      const bearer = opts.bearer ?? (await h.token(dev, "device"));
      const init: Parameters<Harness["req"]>[1] = {
        method: "POST", bearer, body: raw,
        headers: { "content-type": "application/json", "offload-signature": `keyid=${opts.keyid ?? dev.deviceId}, sig=${sig}` },
      };
      if (opts.app) init.app = opts.app;
      return h.req("/v1/ingest/batches", init);
    },
    async consent(dev) {
      const res = await h.req("/v1/me/consents", {
        method: "POST", bearer: await h.token(dev, "member"),
        json: { notice_id: "what-leaves-your-mac", notice_version: "1", device_id: dev.deviceId },
      });
      expect(res.status).toBe(201);
      return res;
    },
    async count(table, dev) {
      const r = await fx.admin.query(`select count(*)::int as n from ${table} where tenant_id = $1 and device_id = $2`, [dev.tenant.tenantId, dev.deviceId]);
      return r.rows[0].n as number;
    },
    close: () => fx.close(),
  };
  return h;
}

let counter = 0;
/** A ULID that sorts after the previous one made in this process. */
export const objectId = (ms: number = Date.now()) => ulid(ms + counter++);

export interface Obj {
  id: string;
  ts: string;
  kind: string;
  [k: string]: unknown;
}

export const focus = (h: Harness, over: Record<string, unknown> = {}): Obj => ({
  id: objectId(), ts: h.clock.now().toISOString(), kind: "focus", app_bundle_id: "com.apple.mail", app_name: "Mail", ...over,
});

export const textSnapshot = (h: Harness, text: string, over: Record<string, unknown> = {}): Obj => ({
  id: objectId(), ts: h.clock.now().toISOString(), kind: "text_snapshot", text_source: "ax", app_bundle_id: "com.apple.mail",
  text, text_hash: sha256Hex(text), ...over,
});

export function envelope(h: Harness, dev: TestDevice, seq: number, objects: unknown[], over: Record<string, unknown> = {}) {
  return { v: 1, device_id: dev.deviceId, seq, sent_at: h.clock.now().toISOString(), kind: "observation_batch", objects, ...over };
}

export interface Receipt {
  accepted: string[];
  rejected: { id: string; code: string }[];
}

export const receiptOf = async (res: Response): Promise<Receipt> => (await res.json()) as Receipt;
export const errorCode = async (res: Response): Promise<string> => ((await res.json()) as { error: { code: string } }).error.code;
