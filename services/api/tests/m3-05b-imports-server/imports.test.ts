import { afterAll, beforeAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import * as contracts from "@offload/contracts";
import { onBeforeCommit } from "@offload/testkit";
import { errorCode, focus, makeHarness, receiptOf, type Harness } from "../m3-01-ingest-batches/harness.ts";
import {
  DAY_MS, consentingDevice, forgetImport, forgetRes, imported, ingestObjects, openImport, openImportRes, outboxWithImport,
  rowsWithImport, webSession,
} from "./helpers.ts";

let h: Harness;
beforeAll(async () => {
  h = await makeHarness();
});
afterAll(async () => {
  await h?.close();
});

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const today = () => h.clock.now().toISOString().slice(0, 10);
const daysAgo = (n: number) => new Date(h.clock.now().getTime() - n * DAY_MS).toISOString();

interface ImportRow { id: string; source_kind: string; first_day: string | null; last_day: string | null; created_at: string }

async function listImports(dev: Parameters<typeof openImport>[1]): Promise<ImportRow[]> {
  const res = await h.req("/v1/imports", { bearer: await h.token(dev, "member") });
  expect(res.status).toBe(200);
  return (await res.json()) as ImportRow[];
}

test("IMPORT: POST /v1/imports opens an import space for the member and audits it", async () => {
  const dev = await consentingDevice(h, h.fx.a, h.fx.a.owner);
  const res = await openImportRes(h, dev, { source_kind: "screenshots" });
  expect(res.status).toBe(201);
  const body = (await res.json()) as { import_id: string };
  expect(Object.keys(body)).toEqual(["import_id"]);
  expect(body.import_id).toMatch(UUID_RE);
  const row = (await h.fx.admin.query(
    "select tenant_id, member_id, source_kind, first_day, last_day, wiped_at from imports where id = $1", [body.import_id])).rows;
  expect(row).toEqual([{ tenant_id: h.fx.a.tenantId, member_id: h.fx.a.owner, source_kind: "screenshots", first_day: null, last_day: null, wiped_at: null }]);
  const audit = (await h.fx.admin.query(
    "select principal_id, subject_type, subject_id, details from audit_events where tenant_id = $1 and action = 'import.opened' and subject_id = $2",
    [h.fx.a.tenantId, body.import_id])).rows;
  expect(audit).toEqual([{ principal_id: h.fx.a.owner, subject_type: "import", subject_id: body.import_id, details: { source_kind: "screenshots" } }]);
});

test("IMPORT: POST /v1/imports refuses an unknown source_kind, extra keys and a missing body with 400 invalid_request", async () => {
  const dev = await consentingDevice(h, h.fx.a, h.fx.a.member);
  const before = (await h.fx.admin.query("select count(*)::int as n from imports where member_id = $1", [h.fx.a.member])).rows[0].n;
  for (const bad of [{ source_kind: "mixed" }, { source_kind: "videos", folder: "Desktop" }, {}, [], "videos"]) {
    const res = await openImportRes(h, dev, bad);
    expect(res.status).toBe(400);
    expect(await errorCode(res)).toBe("invalid_request");
  }
  const noJson = await h.req("/v1/imports", { method: "POST", bearer: await h.token(dev, "member"), body: "source_kind=videos", headers: { "content-type": "application/x-www-form-urlencoded" } });
  expect(noJson.status).toBe(400);
  const after = (await h.fx.admin.query("select count(*)::int as n from imports where member_id = $1", [h.fx.a.member])).rows[0].n;
  expect(after).toBe(before);
});

test("IMPORT: the import routes need a member token or a session with CSRF", async () => {
  const dev = await consentingDevice(h, h.fx.a, h.fx.a.owner);
  const importId = await openImport(h, dev);
  expect((await h.req("/v1/imports")).status).toBe(401);
  expect((await h.req("/v1/imports", { method: "POST", json: { source_kind: "videos" } })).status).toBe(401);
  const deviceToken = await h.token(dev, "device");
  expect((await h.req("/v1/imports", { bearer: deviceToken })).status).toBe(401);
  expect((await h.req("/v1/me/forget", { method: "POST", bearer: deviceToken, json: { scope: "import", import_id: importId } })).status).toBe(401);

  const csrf = "csrf-token-for-the-import-test";
  const cookie = await webSession(h, h.fx.a, h.fx.a.owner, csrf);
  const listed = await h.req("/v1/imports", { headers: { cookie } });
  expect(listed.status).toBe(200);
  expect(((await listed.json()) as ImportRow[]).map((i) => i.id)).toContain(importId);
  const noCsrf = await h.req("/v1/imports", { method: "POST", headers: { cookie }, json: { source_kind: "videos" } });
  expect(noCsrf.status).toBe(403);
  const forgetNoCsrf = await h.req("/v1/me/forget", { method: "POST", headers: { cookie }, json: { scope: "import", import_id: importId } });
  expect(forgetNoCsrf.status).toBe(403);
  expect((await h.fx.admin.query("select count(*)::int as n from imports where id = $1", [importId])).rows[0].n).toBe(1);
  const withCsrf = await h.req("/v1/imports", { method: "POST", headers: { cookie, "x-csrf-token": csrf }, json: { source_kind: "videos" } });
  expect(withCsrf.status).toBe(201);
});

test("IMPORT: GET /v1/imports lists only the member's own import spaces, newest first", async () => {
  const mine = await consentingDevice(h, h.fx.b, h.fx.b.member);
  const colleague = await consentingDevice(h, h.fx.b, h.fx.b.owner);
  const stranger = await consentingDevice(h, h.fx.a, h.fx.a.member);
  const first = await openImport(h, mine, "videos");
  h.clock.advance(1000);
  const second = await openImport(h, mine, "screenwatch");
  const theirs = await openImport(h, colleague);
  const strangers = await openImport(h, stranger);
  const list = await listImports(mine);
  expect(list.map((i) => i.id)).toEqual([second, first]);
  expect(list.map((i) => i.id)).not.toContain(theirs);
  expect(list.map((i) => i.id)).not.toContain(strangers);
  expect(list[0]).toEqual({ id: second, source_kind: "screenwatch", first_day: null, last_day: null, created_at: expect.any(String) });
  for (const i of list) expect(contracts.ImportSchema.safeParse(i).success).toBe(true);
});

test("IMPORT: an imported object older than 7 days is accepted and its day is the ingest date", async () => {
  const dev = await consentingDevice(h, h.fx.a, h.fx.a.owner);
  const importId = await openImport(h, dev);
  const old = daysAgo(10);
  const objects = imported(importId, old);
  const res = await ingestObjects(h, dev, objects);
  expect(res.status).toBe(200);
  expect(await receiptOf(res)).toEqual({ accepted: objects.map((o) => o.id), rejected: [] });
  const obs = (await h.fx.admin.query(
    "select day::text as day, ts, source, import_id from observations where import_id = $1", [importId])).rows;
  expect(obs).toEqual([{ day: today(), ts: new Date(old), source: "import", import_id: importId }]);
  const txt = (await h.fx.admin.query(
    "select day::text as day, ts, source, import_id, text_source from observation_texts where import_id = $1", [importId])).rows;
  expect(txt).toEqual([{ day: today(), ts: new Date(old), source: "import", import_id: importId, text_source: "ocr" }]);
  // The same age without the import space is still too old.
  const live = focus(h, { ts: old });
  expect(await receiptOf(await ingestObjects(h, dev, [live]))).toEqual({ accepted: [], rejected: [{ id: live.id, code: "too_old" }] });
});

test("IMPORT: accepted imported objects set the import's first_day and last_day from their ts", async () => {
  const dev = await consentingDevice(h, h.fx.a, h.fx.a.owner);
  const importId = await openImport(h, dev);
  const day = (n: number) => daysAgo(n).slice(0, 10);
  expect((await ingestObjects(h, dev, imported(importId, daysAgo(12)))).status).toBe(200);
  expect((await ingestObjects(h, dev, [...imported(importId, daysAgo(20)), ...imported(importId, daysAgo(3))])).status).toBe(200);
  expect((await ingestObjects(h, dev, imported(importId, daysAgo(15)))).status).toBe(200);
  const row = (await listImports(dev)).find((i) => i.id === importId);
  expect(row).toMatchObject({ first_day: day(20), last_day: day(3) });
  // A rejected object does not widen the range.
  const future = imported(importId, new Date(h.clock.now().getTime() + DAY_MS).toISOString());
  const r = await receiptOf(await ingestObjects(h, dev, future));
  expect(r.rejected.map((x) => x.code)).toEqual(["schema_invalid", "schema_invalid"]);
  expect((await listImports(dev)).find((i) => i.id === importId)).toMatchObject({ first_day: day(20), last_day: day(3) });
});

test("IMPORT: an imported object whose import was never opened, is another member's or was forgotten is rejected schema_invalid", async () => {
  const dev = await consentingDevice(h, h.fx.a, h.fx.a.owner);
  const colleague = await consentingDevice(h, h.fx.a, h.fx.a.member);
  const stranger = await consentingDevice(h, h.fx.b, h.fx.b.owner);
  const theirs = await openImport(h, colleague);
  const strangers = await openImport(h, stranger);
  const forgotten = await openImport(h, dev);
  await forgetImport(h, dev, forgotten);
  const never = "0192f0a0-0000-7000-8000-000000000001";
  for (const id of [never, theirs, strangers, forgotten]) {
    const objects = imported(id, daysAgo(1));
    const r = await receiptOf(await ingestObjects(h, dev, objects));
    expect(r).toEqual({ accepted: [], rejected: objects.map((o) => ({ id: o.id, code: "schema_invalid" })) });
    expect(await rowsWithImport(h, "observations", id)).toBe(0);
    expect(await rowsWithImport(h, "observation_texts", id)).toBe(0);
  }
});

test("IMPORT: a live object that carries an import_id is rejected schema_invalid", async () => {
  const dev = await consentingDevice(h, h.fx.a, h.fx.a.owner);
  const importId = await openImport(h, dev);
  const liveTagged = focus(h, { source: "live", import_id: importId });
  const untagged = focus(h, { import_id: importId });
  const r = await receiptOf(await ingestObjects(h, dev, [liveTagged, untagged]));
  expect(r).toEqual({ accepted: [], rejected: [{ id: liveTagged.id, code: "schema_invalid" }, { id: untagged.id, code: "schema_invalid" }] });
  expect(await rowsWithImport(h, "observations", importId)).toBe(0);
});

test("IMPORT: the outbox gets one observations.ingested event for live objects and one per import space", async () => {
  const dev = await consentingDevice(h, h.fx.a, h.fx.a.owner);
  const one = await openImport(h, dev);
  const two = await openImport(h, dev);
  const objects = [focus(h), ...imported(one, daysAgo(9)), ...imported(two, daysAgo(2)), imported(two, daysAgo(2))[0]!];
  expect((await ingestObjects(h, dev, objects)).status).toBe(200);
  const rows = (await h.fx.admin.query(
    "select type, version, payload from events_outbox where payload->>'device_id' = $1", [dev.deviceId])).rows;
  const key = (r: { payload: { import_id?: string } }) => r.payload.import_id ?? "";
  rows.sort((a, b) => (key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0));
  const seq = rows[0]?.payload.seq;
  const expected = [
    { type: "observations.ingested", version: 1, payload: { device_id: dev.deviceId, member_id: dev.memberId, seq, accepted: 1 } },
    { type: "observations.ingested", version: 1, payload: { device_id: dev.deviceId, member_id: dev.memberId, seq, accepted: 2, import_id: one } },
    { type: "observations.ingested", version: 1, payload: { device_id: dev.deviceId, member_id: dev.memberId, seq, accepted: 3, import_id: two } },
  ].sort((a, b) => (key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0));
  expect(rows).toEqual(expected);
});

test("IMPORT: forget import wipes every row with that import_id", async () => {
  await h.fx.admin.query("select ensure_partitions($1::date, 1)", [today()]);
  const dev = await consentingDevice(h, h.fx.a, h.fx.a.owner);
  const importId = await openImport(h, dev);
  expect((await ingestObjects(h, dev, imported(importId, daysAgo(30)))).status).toBe(200);
  h.clock.advance(DAY_MS); // the second batch lands in the default partition (no daily partition for tomorrow yet)
  expect((await ingestObjects(h, dev, imported(importId, daysAgo(8)))).status).toBe(200);
  const events = (await h.fx.admin.query("select tenant_id, id from events_outbox where payload->>'import_id' = $1", [importId])).rows;
  expect(events).toHaveLength(2);
  // A dispatcher already claimed one of the events.
  await h.fx.admin.query(
    "insert into outbox_deliveries (tenant_id, event_id, consumer, attempts) values ($1, $2, 'workflow:outbox_dispatch', 1)",
    [events[0].tenant_id, events[0].id]);
  const days = (await h.fx.admin.query("select distinct day::text as d from observations where import_id = $1 order by 1", [importId])).rows.map((r) => r.d);
  expect(days).toHaveLength(2);
  expect(await rowsWithImport(h, "observations", importId)).toBe(2);
  expect(await rowsWithImport(h, "observation_texts", importId)).toBe(2);

  await forgetImport(h, dev, importId);

  expect(await rowsWithImport(h, "observations", importId)).toBe(0);
  expect(await rowsWithImport(h, "observation_texts", importId)).toBe(0);
  expect(await outboxWithImport(h, importId)).toBe(0);
  expect((await h.fx.admin.query("select count(*)::int as n from outbox_deliveries where event_id = any($1::uuid[])", [events.map((e) => e.id)])).rows[0].n).toBe(0);
  expect((await h.fx.admin.query("select count(*)::int as n from imports where id = $1", [importId])).rows[0].n).toBe(0);
  expect((await listImports(dev)).map((i) => i.id)).not.toContain(importId);
});

test("IMPORT: forget leaves live rows, other import spaces and other members' imports alone", async () => {
  const dev = await consentingDevice(h, h.fx.b, h.fx.b.owner);
  const colleague = await consentingDevice(h, h.fx.b, h.fx.b.member);
  const gone = await openImport(h, dev);
  const kept = await openImport(h, dev);
  const theirs = await openImport(h, colleague);
  const live = focus(h);
  expect((await ingestObjects(h, dev, [live, ...imported(gone, daysAgo(9)), ...imported(kept, daysAgo(9))])).status).toBe(200);
  expect((await ingestObjects(h, colleague, imported(theirs, daysAgo(9)))).status).toBe(200);

  await forgetImport(h, dev, gone);

  expect(await rowsWithImport(h, "observations", gone)).toBe(0);
  expect(await rowsWithImport(h, "observations", kept)).toBe(1);
  expect(await rowsWithImport(h, "observation_texts", kept)).toBe(1);
  expect(await rowsWithImport(h, "observations", theirs)).toBe(1);
  expect(await rowsWithImport(h, "observation_texts", theirs)).toBe(1);
  expect((await h.fx.admin.query("select count(*)::int as n from observations where object_id = $1", [live.id])).rows[0].n).toBe(1);
  expect(await outboxWithImport(h, kept)).toBe(1);
  expect(await outboxWithImport(h, theirs)).toBe(1);
  const liveEvents = (await h.fx.admin.query(
    "select count(*)::int as n from events_outbox where payload->>'device_id' = $1 and not payload ? 'import_id'", [dev.deviceId])).rows[0].n;
  expect(liveEvents).toBe(1);
  const mineNow = (await listImports(dev)).map((i) => i.id);
  expect(mineNow).toContain(kept);
  expect(mineNow).not.toContain(gone);
  expect((await listImports(colleague)).map((i) => i.id)).toContain(theirs);
});

test("IMPORT: forget writes a done purge request, a purge_log row with counts and an audit event with ids only", async () => {
  const dev = await consentingDevice(h, h.fx.a, h.fx.a.member);
  const other = await consentingDevice(h, h.fx.a, h.fx.a.owner);
  const importId = await openImport(h, dev);
  expect((await ingestObjects(h, dev, [...imported(importId, daysAgo(9)), ...imported(importId, daysAgo(8))])).status).toBe(200);
  const purgeId = await forgetImport(h, dev, importId);
  expect(purgeId).toMatch(UUID_RE);

  const req = (await h.fx.admin.query(
    "select member_id, scope, scope_ref, state, requested_by, finished_at is not null as finished from purge_requests where id = $1", [purgeId])).rows;
  expect(req).toEqual([{ member_id: h.fx.a.member, scope: "import", scope_ref: importId, state: "done", requested_by: h.fx.a.member, finished: true }]);
  const log = (await h.fx.admin.query("select scope, scope_ref, rows_deleted, requested_by from purge_log where purge_request_id = $1", [purgeId])).rows;
  expect(log).toEqual([{ scope: "import", scope_ref: importId, requested_by: h.fx.a.member, rows_deleted: { observations: 2, observation_texts: 2, events_outbox: 1, imports: 1 } }]);
  const audit = (await h.fx.admin.query(
    "select principal_id, subject_type, subject_id, details from audit_events where tenant_id = $1 and action = 'privacy.forgotten' and subject_id = $2",
    [h.fx.a.tenantId, purgeId])).rows;
  expect(audit).toEqual([{ principal_id: h.fx.a.member, subject_type: "purge_request", subject_id: purgeId, details: { scope: "import", import_id: importId, purge_request_id: purgeId } }]);

  const state = await h.req(`/v1/purge-requests/${purgeId}`, { bearer: await h.token(dev, "member") });
  expect(state.status).toBe(200);
  expect(await state.json()).toEqual({ state: "done" });
  const notYours = await h.req(`/v1/purge-requests/${purgeId}`, { bearer: await h.token(other, "member") });
  expect(notYours.status).toBe(404);
  expect((await h.req("/v1/purge-requests/not-a-uuid", { bearer: await h.token(dev, "member") })).status).toBe(404);
});

test("IMPORT: forget for an unknown, already forgotten or another member's import is 404 and deletes nothing", async () => {
  const dev = await consentingDevice(h, h.fx.a, h.fx.a.owner);
  const colleague = await consentingDevice(h, h.fx.a, h.fx.a.member);
  const stranger = await consentingDevice(h, h.fx.b, h.fx.b.owner);
  const theirs = await openImport(h, colleague);
  const strangers = await openImport(h, stranger);
  expect((await ingestObjects(h, colleague, imported(theirs, daysAgo(9)))).status).toBe(200);
  expect((await ingestObjects(h, stranger, imported(strangers, daysAgo(9)))).status).toBe(200);
  const mine = await openImport(h, dev);
  await forgetImport(h, dev, mine);
  const purgesBefore = (await h.fx.admin.query("select count(*)::int as n from purge_requests")).rows[0].n;
  for (const id of ["0192f0a0-0000-7000-8000-0000000000ff", mine, theirs, strangers]) {
    const res = await forgetRes(h, dev, { scope: "import", import_id: id });
    expect(res.status).toBe(404);
    expect(await errorCode(res)).toBe("not_found");
  }
  expect(await rowsWithImport(h, "observations", theirs)).toBe(1);
  expect(await rowsWithImport(h, "observations", strangers)).toBe(1);
  expect((await h.fx.admin.query("select count(*)::int as n from imports where id = any($1::uuid[])", [[theirs, strangers]])).rows[0].n).toBe(2);
  expect((await h.fx.admin.query("select count(*)::int as n from purge_requests")).rows[0].n).toBe(purgesBefore);
});

test("IMPORT: forget scopes other than import and malformed bodies are 400 invalid_request", async () => {
  const dev = await consentingDevice(h, h.fx.a, h.fx.a.owner);
  const importId = await openImport(h, dev);
  const bad = [
    { scope: "all" },
    { scope: "entity", entity_id: importId },
    { scope: "range", from: "2026-11-01", to: "2026-11-02" },
    { scope: "import" },
    { scope: "import", import_id: "not-a-uuid" },
    { scope: "import", import_id: importId, extra: true },
    { scope: "everything", import_id: importId },
    [],
  ];
  for (const body of bad) {
    const res = await forgetRes(h, dev, body);
    expect(res.status).toBe(400);
    expect(await errorCode(res)).toBe("invalid_request");
  }
  expect((await h.fx.admin.query("select count(*)::int as n from imports where id = $1", [importId])).rows[0].n).toBe(1);
});

test("IMPORT: an import forgotten while its batch is being checked stores nothing for it", async () => {
  const dev = await consentingDevice(h, h.fx.a, h.fx.a.owner);
  const importId = await openImport(h, dev);
  const objects = imported(importId, daysAgo(9));
  const live = focus(h);
  let deviceTx = 0;
  let forgot: Response | null = null;
  // Ingest runs device-principal transactions in order: public key, seq state, per-object context (reads the open
  // import spaces), insert. Forget commits right after the third, between the check and the insert.
  const remove = onBeforeCommit(async (tx) => {
    const p = (await tx.query("select current_setting('app.principal_id', true) as p")).rows[0].p;
    if (p !== dev.deviceId) return;
    deviceTx += 1;
    if (deviceTx === 3) forgot = await forgetRes(h, dev, { scope: "import", import_id: importId });
  });
  let res: Response;
  try {
    res = await ingestObjects(h, dev, [live, ...objects]);
  } finally {
    remove();
  }
  expect(forgot!.status).toBe(202);
  expect(res.status).toBe(200);
  expect(await receiptOf(res)).toEqual({ accepted: [live.id], rejected: objects.map((o) => ({ id: o.id, code: "schema_invalid" })) });
  expect(await rowsWithImport(h, "observations", importId)).toBe(0);
  expect(await rowsWithImport(h, "observation_texts", importId)).toBe(0);
  expect(await outboxWithImport(h, importId)).toBe(0);
  expect((await h.fx.admin.query("select count(*)::int as n from observations where object_id = $1", [live.id])).rows[0].n).toBe(1);
});

test("IMPORT: the contracts accept the API.md bodies and the JSON Schemas agree", async () => {
  const c = contracts as unknown as Record<string, { safeParse(v: unknown): { success: boolean } }>;
  for (const name of ["OpenImportRequestSchema", "OpenImportResponseSchema", "ImportSchema", "ForgetRequestSchema", "ForgetResponseSchema", "PurgeRequestStateSchema"]) {
    expect(c[name]).toBeDefined();
  }
  const id = "0192f0a0-0000-7000-8000-000000000001";
  expect(c["OpenImportRequestSchema"]!.safeParse({ source_kind: "videos" }).success).toBe(true);
  expect(c["OpenImportRequestSchema"]!.safeParse({ source_kind: "mixed" }).success).toBe(false);
  expect(c["OpenImportRequestSchema"]!.safeParse({ source_kind: "videos", x: 1 }).success).toBe(false);
  expect(c["OpenImportResponseSchema"]!.safeParse({ import_id: id }).success).toBe(true);
  expect(c["ImportSchema"]!.safeParse({ id, source_kind: "screenwatch", first_day: "2026-11-01", last_day: null, created_at: "2026-11-14T09:00:00.000Z" }).success).toBe(true);
  expect(c["ImportSchema"]!.safeParse({ id, source_kind: "screenwatch", first_day: "1 Nov", last_day: null, created_at: "2026-11-14T09:00:00.000Z" }).success).toBe(false);
  expect(c["ForgetRequestSchema"]!.safeParse({ scope: "import", import_id: id }).success).toBe(true);
  expect(c["ForgetRequestSchema"]!.safeParse({ scope: "range", from: "2026-11-01", to: "2026-11-02" }).success).toBe(true);
  expect(c["ForgetRequestSchema"]!.safeParse({ scope: "import", import_id: id, extra: 1 }).success).toBe(false);
  expect(c["ForgetResponseSchema"]!.safeParse({ purge_request_id: id }).success).toBe(true);
  expect(c["PurgeRequestStateSchema"]!.safeParse({ state: "done" }).success).toBe(true);
  expect(c["PurgeRequestStateSchema"]!.safeParse({ state: "gone" }).success).toBe(false);

  const dir = join(import.meta.dir, "../../../../packages/contracts/schemas");
  for (const file of ["open-import-request", "import", "forget-request", "purge-request-state"]) {
    const s = JSON.parse(readFileSync(join(dir, `${file}.schema.json`), "utf8")) as { $id: string; type: string; additionalProperties: boolean };
    expect(s.$id).toBe(`https://offload.consultance.ai/schemas/${file}.json`);
    expect(s.type).toBe("object");
    expect(s.additionalProperties).toBe(false);
  }
});
