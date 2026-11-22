import { afterAll, beforeAll, expect, test } from "bun:test";
import { envelope, focus, makeHarness, receiptOf, textSnapshot, type Harness, type Obj, type TestDevice } from "./harness.ts";

let h: Harness;
let dev: TestDevice;
let seq = 0;
beforeAll(async () => {
  h = await makeHarness();
  dev = await h.device(h.fx.a, h.fx.a.owner);
  await h.consent(dev);
});
afterAll(async () => {
  await h?.close();
});

/** Posts one batch and returns its receipt. */
async function send(objects: Obj[]) {
  const res = await h.ingest(dev, envelope(h, dev, ++seq, objects));
  expect(res.status).toBe(200);
  return receiptOf(res);
}

const leakAudits = async () =>
  (await h.fx.admin.query("select principal_id, subject_type, details from audit_events where tenant_id = $1 and action = 'privacy.leak_blocked' order by seq", [dev.tenant.tenantId])).rows;

// Secret-shaped strings are assembled at run time so this file holds no literal that looks like a credential.
const anthropicKey = () => "sk-" + "ant-api03-" + "Zk3".repeat(14);

test("LEAK: an email address in text is rejected leak_detected and audited", async () => {
  const before = (await leakAudits()).length;
  const leaky = textSnapshot(h, "Please write to dana.smith@example.test today");
  const clean = textSnapshot(h, "Please write to <email:h_0123456789abcdef> today");
  const r = await send([leaky, clean]);
  expect(r).toEqual({ accepted: [clean.id], rejected: [{ id: leaky.id, code: "leak_detected" }] });
  const rows = await leakAudits();
  expect(rows).toHaveLength(before + 1);
  const row = rows.at(-1)!;
  expect(row.details).toEqual({ object_id: leaky.id, detector: "email" });
  expect(JSON.stringify(row)).not.toContain("dana");
  const stored = (await h.fx.admin.query("select count(*)::int as n from observation_texts where device_id = $1 and object_id = $2", [dev.deviceId, leaky.id])).rows[0].n;
  expect(stored).toBe(0);
});

test("LEAK: a card number passing Luhn is rejected", async () => {
  const luhn = focus(h, { title: "Pay with 4111 1111 1111 1111 now" });
  const dashed = textSnapshot(h, "card 5500-0000-0000-0004 on file");
  const notLuhn = focus(h, { title: "Order 4111 1111 1111 1112 shipped" });
  const r = await send([luhn, dashed, notLuhn]);
  expect(r).toEqual({ accepted: [notLuhn.id], rejected: [{ id: luhn.id, code: "leak_detected" }, { id: dashed.id, code: "leak_detected" }] });
  const detectors = (await leakAudits()).slice(-2).map((x) => (x.details as { detector: string }).detector);
  expect(detectors).toEqual(["card", "card"]);
});

test("LEAK: an sk-ant style key is rejected", async () => {
  const key = textSnapshot(h, `export KEY=${anthropicKey()} and go`);
  const bearer = focus(h, { title: "Authorization: Bearer abcdef0123456789abcdef" });
  const pem = textSnapshot(h, "-----BEGIN " + "PRIVATE KEY-----\nMIIBVgIBADANBg");
  const aws = focus(h, { title: "id " + "AKIA" + "ABCDEFGHIJKLMNOP" });
  const ghp = textSnapshot(h, "token " + "ghp_" + "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8");
  const plain = textSnapshot(h, "the skill and the risk of a Bearer market");
  const r = await send([key, bearer, pem, aws, ghp, plain]);
  expect(r.accepted).toEqual([plain.id]);
  expect(r.rejected).toEqual([key, bearer, pem, aws, ghp].map((o) => ({ id: o.id, code: "leak_detected" })));
  const rows = await leakAudits();
  expect(rows.some((x) => JSON.stringify(x.details).includes("sk-"))).toBe(false);
});

test("LEAK: a URL with a query string in title is rejected", async () => {
  const query = focus(h, { title: "Inbox https://mail.example.test/u/0/?token=abc" });
  const path = focus(h, { title: "Doc https://docs.example.test/d/1AbC/edit" });
  const fragment = textSnapshot(h, "see https://example.test#section-2 for more");
  const bare = focus(h, { title: "Home https://example.test", host: "example.test" });
  const r = await send([query, path, fragment, bare]);
  expect(r).toEqual({
    accepted: [bare.id],
    rejected: [query, path, fragment].map((o) => ({ id: o.id, code: "leak_detected" })),
  });
});

test("LEAK: a valid IBAN and a phone number are rejected", async () => {
  const iban = textSnapshot(h, "Send to GB82 WEST 1234 5698 7654 32 please");
  const ibanCompact = focus(h, { title: "DE89370400440532013000" });
  const e164 = textSnapshot(h, "Call +14155550132 after lunch");
  const spaced = textSnapshot(h, "Call (415) 555-0132 after lunch");
  const dotted = focus(h, { title: "415.555.0132" });
  const year = textSnapshot(h, "Q3 2026 revenue was 1,250,000 across 12 regions");
  const r = await send([iban, ibanCompact, e164, spaced, dotted, year]);
  expect(r.accepted).toEqual([year.id]);
  expect(r.rejected).toEqual([iban, ibanCompact, e164, spaced, dotted].map((o) => ({ id: o.id, code: "leak_detected" })));
  const detectors = (await leakAudits()).slice(-5).map((x) => (x.details as { detector: string }).detector);
  expect(detectors).toEqual(["iban", "iban", "phone", "phone", "phone"]);
});

test("LEAK: pseudonyms and router placeholders pass", async () => {
  const objects = [
    textSnapshot(h, "<person:h_0123456789abcdef> sent <doc:h_0123456789abcdef> to <phone:h_0123456789abcdef>"),
    textSnapshot(h, "<person:qkzt.1> asked <person:qkzt.2.first> and <person:qkzt.me>"),
    focus(h, { title: "Re: <person:h_0123456789abcdef>", doc: "<doc:h_7c1e09b2a4d35f6e>" }),
  ];
  const r = await send(objects);
  expect(r).toEqual({ accepted: objects.map((o) => o.id), rejected: [] });
});
