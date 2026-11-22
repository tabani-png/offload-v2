import { afterAll, beforeAll, expect, test } from "bun:test";
import { jcs, sha256Hex } from "@offload/contracts";
import { uuidv7, withTenant } from "@offload/db";
import { BUILTIN_EXCLUSIONS } from "@offload/masking";
import {
  envelope, errorCode, focus, makeHarness, objectId, receiptOf, textSnapshot, type Harness, type TestDevice,
} from "./harness.ts";

let h: Harness;
beforeAll(async () => {
  h = await makeHarness();
});
afterAll(async () => {
  await h?.close();
});

/** A fresh device of the first tenant's owner, with upload consent. */
async function consenting(tenant = h.fx.a, member = h.fx.a.owner): Promise<TestDevice> {
  const dev = await h.device(tenant, member);
  await h.consent(dev);
  return dev;
}

test("INGEST: a valid batch is stored and every id is accepted", async () => {
  const dev = await consenting();
  const objects = [
    focus(h, { title: "Finance 2026 - Google Sheets", host: "docs.google.com", doc: "<doc:h_7c1e09b2a4d35f6e>" }),
    { id: objectId(), ts: h.clock.now().toISOString(), kind: "input_counts", keys: 12, clicks: 3 },
    { id: objectId(), ts: h.clock.now().toISOString(), kind: "idle_start" },
  ];
  const env = envelope(h, dev, 1, objects);
  const res = await h.ingest(dev, env);
  expect(res.status).toBe(200);
  expect(await receiptOf(res)).toEqual({ accepted: objects.map((o) => o.id), rejected: [] });
  expect(await h.count("observations", dev)).toBe(3);
  const batch = (await h.fx.admin.query("select seq::int as seq, kind, body_sha256, object_count, receipt from ingest_batches where device_id = $1", [dev.deviceId])).rows;
  expect(batch).toEqual([{ seq: 1, kind: "observation_batch", body_sha256: sha256Hex(jcs(env)), object_count: 3, receipt: { accepted: objects.map((o) => o.id), rejected: [] } }]);
  const last = (await h.fx.admin.query("select last_seq::int as s from devices where id = $1", [dev.deviceId])).rows[0].s;
  expect(last).toBe(1);
  const row = (await h.fx.admin.query("select title, host, doc, member_id, day::text as day from observations where device_id = $1 and kind = 'focus'", [dev.deviceId])).rows[0];
  expect(row).toEqual({ title: "Finance 2026 - Google Sheets", host: "docs.google.com", doc: "<doc:h_7c1e09b2a4d35f6e>", member_id: dev.memberId, day: "2026-11-14" });
});

test("INGEST: same batch twice stores objects once and returns the same receipt", async () => {
  const dev = await consenting();
  const env = envelope(h, dev, 1, [focus(h), focus(h, { app_name: "Notes", app_bundle_id: "com.apple.Notes" })]);
  const first = await h.ingest(dev, env);
  const second = await h.ingest(dev, env);
  expect(first.status).toBe(200);
  expect(second.status).toBe(200);
  expect(await receiptOf(second)).toEqual(await receiptOf(first));
  expect(await h.count("observations", dev)).toBe(2);
  expect(await h.count("ingest_batches", dev)).toBe(1);
  const events = (await h.fx.admin.query("select count(*)::int as n from events_outbox where type = 'observations.ingested' and payload->>'device_id' = $1", [dev.deviceId])).rows[0].n;
  expect(events).toBe(1);
});

test("INGEST: identical resend after restart returns the stored receipt", async () => {
  const dev = await consenting();
  const env = envelope(h, dev, 1, [focus(h)]);
  const first = await h.ingest(dev, env);
  const restarted = h.newApp();
  const again = await h.ingest(dev, env, { app: restarted });
  expect(again.status).toBe(200);
  expect(await receiptOf(again)).toEqual(await receiptOf(first));
  expect(await h.count("observations", dev)).toBe(1);
});

test("INGEST: same seq with different bytes is 409 seq_replay", async () => {
  const dev = await consenting();
  expect((await h.ingest(dev, envelope(h, dev, 1, [focus(h)]))).status).toBe(200);
  const other = await h.ingest(dev, envelope(h, dev, 1, [focus(h, { app_name: "Calendar", app_bundle_id: "com.apple.iCal" })]));
  expect(other.status).toBe(409);
  expect(await errorCode(other)).toBe("seq_replay");
  expect(await h.count("observations", dev)).toBe(1);
});

test("INGEST: a seq not above last_seq is 409 seq_replay", async () => {
  const dev = await consenting();
  expect((await h.ingest(dev, envelope(h, dev, 5, [focus(h)]))).status).toBe(200);
  for (const seq of [3, 0]) {
    const res = await h.ingest(dev, envelope(h, dev, seq, [focus(h)]));
    expect({ seq, status: res.status }).toEqual({ seq, status: 409 });
    expect(await errorCode(res)).toBe("seq_replay");
  }
  // A gap upward is fine.
  expect((await h.ingest(dev, envelope(h, dev, 9, [focus(h)]))).status).toBe(200);
  expect(await h.count("observations", dev)).toBe(2);
});

test("INGEST: sent_at off by 11 minutes is 400 clock_skew and nothing is stored", async () => {
  const dev = await consenting();
  for (const minutes of [11, -11]) {
    const sentAt = new Date(h.clock.now().getTime() + minutes * 60_000).toISOString();
    const res = await h.ingest(dev, envelope(h, dev, 1, [focus(h)], { sent_at: sentAt }));
    expect({ minutes, status: res.status }).toEqual({ minutes, status: 400 });
    expect(await errorCode(res)).toBe("clock_skew");
  }
  expect(await h.count("observations", dev)).toBe(0);
  expect(await h.count("ingest_batches", dev)).toBe(0);
  // Nothing was recorded, so the same seq is still free.
  expect((await h.ingest(dev, envelope(h, dev, 1, [focus(h)]))).status).toBe(200);
});

test("INGEST: a bad signature is 401 and nothing is stored", async () => {
  const dev = await consenting();
  const other = await h.device(h.fx.a, h.fx.a.owner);
  const env = envelope(h, dev, 1, [focus(h)]);
  const wrongKey = await h.ingest(dev, env, { signWith: other.key });
  expect(wrongKey.status).toBe(401);
  expect(await errorCode(wrongKey)).toBe("unauthenticated");
  const tampered = await h.ingest(dev, env, { sig: await dev.key.sign(jcs(envelope(h, dev, 1, [focus(h)]))) });
  expect(tampered.status).toBe(401);
  const noHeader = await h.req("/v1/ingest/batches", { method: "POST", bearer: await h.token(dev, "device"), body: jcs(env), headers: { "content-type": "application/json" } });
  expect(noHeader.status).toBe(401);
  expect(await h.count("observations", dev)).toBe(0);
  expect(await h.count("ingest_batches", dev)).toBe(0);
});

test("INGEST: a DER signature or a non-JCS body is rejected", async () => {
  const dev = await consenting();
  const env = envelope(h, dev, 1, [focus(h)]);
  const der = await h.ingest(dev, env, { sig: await dev.key.signDer(jcs(env)) });
  expect(der.status).toBe(401);
  // Valid signature over bytes that are JSON but not JCS (spaces, key order).
  const pretty = JSON.stringify(env, null, 1);
  const notJcs = await h.ingest(dev, env, { rawBody: pretty, sig: await dev.key.sign(pretty) });
  expect(notJcs.status).toBe(400);
  expect(await errorCode(notJcs)).toBe("invalid_request");
  const notJson = await h.ingest(dev, env, { rawBody: "not json", sig: await dev.key.sign("not json") });
  expect(notJson.status).toBe(400);
  expect(await h.count("observations", dev)).toBe(0);
});

test("INGEST: envelope device_id different from the token's device is 403", async () => {
  const mine = await consenting();
  const theirs = await consenting(h.fx.b, h.fx.b.owner);
  // Tenant A's token and key, tenant B's device id in the envelope.
  const res = await h.ingest(mine, envelope(h, theirs, 1, [focus(h)]));
  expect(res.status).toBe(403);
  expect(await errorCode(res)).toBe("forbidden");
  // keyid naming another device is refused the same way.
  const keyid = await h.ingest(mine, envelope(h, mine, 1, [focus(h)]), { keyid: theirs.deviceId });
  expect(keyid.status).toBe(403);
  expect(await h.count("observations", theirs)).toBe(0);
  expect(await h.count("ingest_batches", theirs)).toBe(0);
  expect(await h.count("observations", mine)).toBe(0);
});

test("INGEST: kind run_outcome is rejected unknown_kind", async () => {
  const dev = await consenting();
  const res = await h.ingest(dev, envelope(h, dev, 1, [focus(h)], { kind: "run_outcome" }));
  expect(res.status).toBe(400);
  expect(await errorCode(res)).toBe("unknown_kind");
  expect(await h.count("ingest_batches", dev)).toBe(0);
});

test("INGEST: keyframe envelopes on /batches are 400 unknown_kind", async () => {
  const dev = await consenting();
  const meta = { id: objectId(), ts: h.clock.now().toISOString(), phash: "0123456789abcdef", width: 1280, height: 800, bytes: 1000, sha256: sha256Hex("x") };
  const res = await h.ingest(dev, envelope(h, dev, 1, [meta], { kind: "keyframe" }));
  expect(res.status).toBe(400);
  expect(await errorCode(res)).toBe("unknown_kind");
});

test("INGEST: review_event, notice_ack and step_result objects are rejected not_enabled", async () => {
  const dev = await consenting();
  const ts = h.clock.now().toISOString();
  const cases: [string, Record<string, unknown>][] = [
    ["review_event", { id: objectId(), ts, run_id: uuidv7(), review_seconds: 4, edit_seconds: 0, fix_seconds: 0, items_edited: 0, decision: "approved", surface: "mac" }],
    ["notice_ack", { id: objectId(), ts, notice_id: uuidv7(), notice_version: "1" }],
    ["step_result", { id: objectId(), ts, command_id: uuidv7(), item_hash: sha256Hex("item"), outcome: "sent", finished_at: ts }],
  ];
  let seq = 1;
  for (const [kind, obj] of cases) {
    const res = await h.ingest(dev, envelope(h, dev, seq++, [obj], { kind }));
    expect({ kind, status: res.status }).toEqual({ kind, status: 200 });
    expect(await receiptOf(res)).toEqual({ accepted: [], rejected: [{ id: obj["id"] as string, code: "not_enabled" }] });
  }
  expect(await h.count("observations", dev)).toBe(0);
});

test("INGEST: an object older than 7 days is too_old and one 11 minutes in the future is schema_invalid", async () => {
  const dev = await consenting();
  const now = h.clock.now().getTime();
  const old = focus(h, { ts: new Date(now - 7 * 86_400_000 - 60_000).toISOString() });
  const edge = focus(h, { ts: new Date(now - 6 * 86_400_000).toISOString() });
  const future = focus(h, { ts: new Date(now + 11 * 60_000).toISOString() });
  const soon = focus(h, { ts: new Date(now + 9 * 60_000).toISOString() });
  const bad = { id: objectId(), ts: h.clock.now().toISOString(), kind: "focus", app_name: "Mail" };
  const res = await h.ingest(dev, envelope(h, dev, 1, [old, edge, future, soon, bad]));
  expect(res.status).toBe(200);
  expect(await receiptOf(res)).toEqual({
    accepted: [edge.id, soon.id],
    rejected: [{ id: old.id, code: "too_old" }, { id: future.id, code: "schema_invalid" }, { id: bad.id, code: "schema_invalid" }],
  });
  expect(await h.count("observations", dev)).toBe(2);
});

test("INGEST: 1 MiB + 1 byte is 413 too_large", async () => {
  const dev = await consenting();
  const res = await h.ingest(dev, {}, { rawBody: "x".repeat(1024 * 1024 + 1), sig: "A".repeat(86) });
  expect(res.status).toBe(413);
  expect(await errorCode(res)).toBe("too_large");
  expect(await h.count("ingest_batches", dev)).toBe(0);
});

test("INGEST: the 61st request in a minute is 429 rate_limited", async () => {
  const dev = await h.device(h.fx.a, h.fx.a.owner);
  const bearer = await h.token(dev, "device");
  const statuses: number[] = [];
  for (let i = 0; i < 61; i++) statuses.push((await h.ingest(dev, {}, { bearer, rawBody: "{}", sig: "A".repeat(86) })).status);
  expect(statuses.slice(0, 60).every((s) => s === 401)).toBe(true);
  expect(statuses[60]).toBe(429);
  const again = await h.ingest(dev, {}, { bearer, rawBody: "{}", sig: "A".repeat(86) });
  expect(again.status).toBe(429);
  expect(Number(again.headers.get("retry-after"))).toBeGreaterThan(0);
  expect(await errorCode(again)).toBe("rate_limited");
  // The window moves with the clock; another device was never limited.
  h.clock.advanceMinutes(1.5);
  const later = await h.ingest(dev, {}, { bearer: await h.token(dev, "device"), rawBody: "{}", sig: "A".repeat(86) });
  expect(later.status).toBe(401);
});

test("INGEST: an excluded host is rejected excluded", async () => {
  const dev = await consenting(h.fx.b, h.fx.b.owner);
  const builtinHost = BUILTIN_EXCLUSIONS.find((e) => e.kind === "host")!.value;
  const builtinApp = BUILTIN_EXCLUSIONS.find((e) => e.kind === "bundle_id")!.value;
  await withTenant(h.fx.app, h.fx.ctx(h.fx.b, h.fx.b.owner), async (tx) => {
    for (const [kind, value] of [["host", "bank.example"], ["title_contains", "payroll"], ["bundle_id", "com.example.secret"]] as const) {
      await tx.query("insert into exclusions (tenant_id, member_id, id, kind, value, source) values ($1, $2, $3, $4, $5, 'user')", [h.fx.b.tenantId, h.fx.b.owner, uuidv7(), kind, value]);
    }
  });
  const sub = focus(h, { host: `www.${builtinHost}` });
  const exact = focus(h, { host: builtinHost });
  const app = focus(h, { app_bundle_id: builtinApp });
  const user = focus(h, { host: "www.bank.example" });
  const title = focus(h, { title: "Q3 PAYROLL run" });
  const bundle = focus(h, { app_bundle_id: "com.example.secret" });
  const lookalike = focus(h, { host: `not${builtinHost}` });
  const fine = focus(h, { host: "docs.google.com" });
  const res = await h.ingest(dev, envelope(h, dev, 1, [sub, exact, app, user, title, bundle, lookalike, fine]));
  expect(res.status).toBe(200);
  expect(await receiptOf(res)).toEqual({
    accepted: [lookalike.id, fine.id],
    rejected: [sub, exact, app, user, title, bundle].map((o) => ({ id: o.id, code: "excluded" })),
  });
});

test("INGEST: keyframe upload is 403 consent_missing", async () => {
  const dev = await consenting();
  const res = await h.req("/v1/ingest/keyframes", { method: "POST", bearer: await h.token(dev, "device"), body: "x" });
  expect(res.status).toBe(403);
  expect(await errorCode(res)).toBe("consent_missing");
  const noToken = await h.req("/v1/ingest/keyframes", { method: "POST", body: "x" });
  expect(noToken.status).toBe(401);
  const config = await h.req("/v1/ingest/config", { bearer: await h.token(dev, "device") });
  expect(config.status).toBe(200);
  const body = (await config.json()) as Record<string, unknown>;
  expect(body).toMatchObject({ flush_seconds: 300, max_objects: 500, max_bytes: 1048576, keyframes_to_cloud: false });
  expect(Array.isArray(body["exclusions"])).toBe(true);
  expect((body["exclusions"] as unknown[]).length).toBe(BUILTIN_EXCLUSIONS.length);
});

test("INGEST: text snapshots land in observation_texts and other kinds in observations", async () => {
  const dev = await consenting();
  const text = "Reply to <person:h_0123456789abcdef> about the invoice";
  const snap = textSnapshot(h, text);
  const f = focus(h);
  const res = await h.ingest(dev, envelope(h, dev, 1, [f, snap]));
  expect(await receiptOf(res)).toEqual({ accepted: [f.id, snap.id], rejected: [] });
  expect(await h.count("observations", dev)).toBe(1);
  expect(await h.count("observation_texts", dev)).toBe(1);
  const row = (await h.fx.admin.query("select text, text_hash, text_source, app_bundle_id, member_id from observation_texts where device_id = $1", [dev.deviceId])).rows[0];
  expect(row).toEqual({ text, text_hash: sha256Hex(text), text_source: "ax", app_bundle_id: "com.apple.mail", member_id: dev.memberId });
  const kinds = (await h.fx.admin.query("select kind from observations where device_id = $1", [dev.deviceId])).rows;
  expect(kinds).toEqual([{ kind: "focus" }]);
});
