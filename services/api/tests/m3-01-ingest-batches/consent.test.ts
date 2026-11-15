import { afterAll, beforeAll, expect, test } from "bun:test";
import { envelope, errorCode, focus, makeHarness, receiptOf, type Harness } from "./harness.ts";

let h: Harness;
beforeAll(async () => {
  h = await makeHarness();
});
afterAll(async () => {
  await h?.close();
});

const audit = async (tenantId: string, action: string) =>
  (await h.fx.admin.query("select principal_id, subject_type, subject_id, details from audit_events where tenant_id = $1 and action = $2 order by seq", [tenantId, action])).rows;

test("CONSENT: observations from a member without upload consent are rejected consent_missing", async () => {
  const dev = await h.device(h.fx.a, h.fx.a.member);
  const objects = [focus(h), focus(h, { app_name: "Notes", app_bundle_id: "com.apple.Notes" })];
  const res = await h.ingest(dev, envelope(h, dev, 1, objects));
  expect(res.status).toBe(200);
  expect(await receiptOf(res)).toEqual({ accepted: [], rejected: objects.map((o) => ({ id: o.id, code: "consent_missing" })) });
  expect(await h.count("observations", dev)).toBe(0);
  expect(await h.count("observation_texts", dev)).toBe(0);
});

test("CONSENT: consent for the current notice version lets the next batch through and is audited", async () => {
  const dev = await h.device(h.fx.b, h.fx.b.owner);
  const blocked = focus(h);
  expect((await receiptOf(await h.ingest(dev, envelope(h, dev, 1, [blocked])))).rejected).toEqual([{ id: blocked.id, code: "consent_missing" }]);
  const res = await h.req("/v1/me/consents", {
    method: "POST", bearer: await h.token(dev, "member"),
    json: { notice_id: "what-leaves-your-mac", notice_version: "1", device_id: dev.deviceId },
  });
  expect(res.status).toBe(201);
  const body = (await res.json()) as Record<string, unknown>;
  expect(body).toMatchObject({ notice_id: "what-leaves-your-mac", notice_version: "1", device_id: dev.deviceId, withdrawn_at: null });
  expect(typeof body["given_at"]).toBe("string");
  const ok = focus(h);
  expect(await receiptOf(await h.ingest(dev, envelope(h, dev, 2, [ok])))).toEqual({ accepted: [ok.id], rejected: [] });
  const rows = await audit(h.fx.b.tenantId, "privacy.consent_given");
  expect(rows).toHaveLength(1);
  expect(rows[0]).toMatchObject({ principal_id: h.fx.b.owner, details: { notice_id: "what-leaves-your-mac", notice_version: "1", device_id: dev.deviceId } });
});

test("CONSENT: a stale notice_version is 409 stale_notice and a withdrawn consent blocks uploads again", async () => {
  const dev = await h.device(h.fx.a, h.fx.a.owner);
  const bearer = await h.token(dev, "member");
  const stale = await h.req("/v1/me/consents", { method: "POST", bearer, json: { notice_id: "what-leaves-your-mac", notice_version: "0", device_id: dev.deviceId } });
  expect(stale.status).toBe(409);
  expect(await errorCode(stale)).toBe("stale_notice");
  expect(await audit(h.fx.a.tenantId, "privacy.consent_given")).toHaveLength(0);
  await h.consent(dev);
  const first = focus(h);
  expect((await receiptOf(await h.ingest(dev, envelope(h, dev, 1, [first])))).accepted).toEqual([first.id]);
  const del = await h.req("/v1/me/consents/what-leaves-your-mac", { method: "DELETE", bearer });
  expect(del.status).toBe(204);
  const second = focus(h);
  expect(await receiptOf(await h.ingest(dev, envelope(h, dev, 2, [second])))).toEqual({ accepted: [], rejected: [{ id: second.id, code: "consent_missing" }] });
  expect(await audit(h.fx.a.tenantId, "privacy.consent_withdrawn")).toHaveLength(1);
  // Consent can be given again.
  await h.consent(dev);
  const third = focus(h);
  expect((await receiptOf(await h.ingest(dev, envelope(h, dev, 3, [third])))).accepted).toEqual([third.id]);
});

test("CONSENT: GET /v1/me reports upload_consent.needed until consent exists", async () => {
  const dev = await h.device(h.fx.b, h.fx.b.member);
  const bearer = await h.token(dev, "member");
  const get = async () => ((await (await h.req("/v1/me", { bearer })).json()) as { upload_consent: unknown }).upload_consent;
  expect(await get()).toEqual({ notice_id: "what-leaves-your-mac", current_version: "1", consented_version: null, needed: true });
  await h.consent(dev);
  expect(await get()).toEqual({ notice_id: "what-leaves-your-mac", current_version: "1", consented_version: "1", needed: false });
  await h.req("/v1/me/consents/what-leaves-your-mac", { method: "DELETE", bearer });
  expect(await get()).toEqual({ notice_id: "what-leaves-your-mac", current_version: "1", consented_version: null, needed: true });
});
