import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { UNDERSTANDING_CONSUMER } from "../../src/understanding/capture.ts";
import { drainUnderstanding, runUnderstanding, understandingWorkflow } from "../../src/understanding/job.ts";
import { brainRows, consumeDb, daysAgo, emitIngested, HAS_DB, insertCapture, instancesByKey, resetRows, todayUtc, type ConsumeDb } from "./db.ts";
import { invoiceImport, NOISE, recordingObservations, rng, utc, merge } from "./fixtures.ts";

const t = HAS_DB ? test : test.skip;
let db: ConsumeDb;
const DAYS = [daysAgo(12), daysAgo(11), daysAgo(10)];

beforeAll(async () => {
  if (HAS_DB) db = await consumeDb();
}, 60_000);
afterAll(async () => {
  if (HAS_DB) await db.close();
});
beforeEach(async () => {
  if (HAS_DB) await resetRows(db);
});

async function importInvoices(memberId: string, deviceId: string, tenant = db.fx.a) {
  const fx = invoiceImport(DAYS, { perDay: 2, noise: true, menuBar: false });
  await insertCapture(db, tenant, memberId, deviceId, fx, todayUtc());
  return fx;
}

t("CONSUME: an import of a repeated workflow yields one task key with N instances and unrelated clips do not merge", async () => {
  const a = db.fx.a;
  const fx = await importInvoices(a.owner, a.devices.owner);
  const ev = await emitIngested(db, a, a.owner, a.devices.owner);
  const r = await runUnderstanding(db.deps, ev);
  expect(r.status).toBe("updated");
  expect(r.days).toEqual(DAYS);
  const byKey = await instancesByKey(db, a.owner);
  const repeated = [...byKey.values()].filter((n) => n > 1);
  expect(repeated).toEqual([fx.instances]);
  expect(fx.instances).toBe(6);
  // The four noise clips with text are four tasks of one instance each.
  expect([...byKey.values()].filter((n) => n === 1)).toHaveLength(4);
  const ledger = (await brainRows(db, a.owner))["task_ledger"]!;
  expect(ledger).toHaveLength(5);
});

t("CONSUME: re-delivery of observations.ingested does nothing twice", async () => {
  const a = db.fx.a;
  await importInvoices(a.owner, a.devices.owner);
  const ev = await emitIngested(db, a, a.owner, a.devices.owner);
  expect((await runUnderstanding(db.deps, ev)).status).toBe("updated");
  const before = await brainRows(db, a.owner);
  const calls = db.brainCalls.n;
  const again = await runUnderstanding(db.deps, ev);
  expect(again.status).toBe("duplicate");
  expect(db.brainCalls.n).toBe(calls);
  expect(await brainRows(db, a.owner)).toEqual(before);
  const d = (await db.fx.admin.query("select attempts, delivered_at, last_error_code from outbox_deliveries where event_id = $1 and consumer = $2", [ev.eventId, UNDERSTANDING_CONSUMER])).rows;
  expect(d).toHaveLength(1);
  expect(d[0].attempts).toBe(1);
  expect(d[0].delivered_at).not.toBeNull();
  expect(d[0].last_error_code).toBeNull();
});

t("CONSUME: imported observations are read by ts and analysed on their own days", async () => {
  const a = db.fx.a;
  await importInvoices(a.owner, a.devices.owner);
  const parts = (await db.fx.admin.query("select distinct day::text as day from observations where member_id = $1", [a.owner])).rows.map((x) => x.day);
  expect(parts).toEqual([todayUtc()]);
  const r = await runUnderstanding(db.deps, await emitIngested(db, a, a.owner, a.devices.owner));
  expect(r.days).toEqual(DAYS);
  const rows = await brainRows(db, a.owner);
  expect((rows["day_records"] as { day: string }[]).map((x) => x.day).sort()).toEqual(DAYS);
});

t("CONSUME: a member's run reads only that member's observations and writes only that member's model", async () => {
  const { a, b } = db.fx;
  await importInvoices(a.owner, a.devices.owner);
  const r2 = rng(99);
  const noise = merge(NOISE.slice(0, 3).map((seg, i) => recordingObservations({ start: utc(DAYS[0]!) + (10 + i) * 3_600_000, segments: [seg] }, r2)));
  await insertCapture(db, a, a.member, a.devices.member, noise, todayUtc());
  await insertCapture(db, b, b.owner, b.devices.owner, invoiceImport(DAYS, { perDay: 1, noise: false, seed: 5 }), todayUtc());

  await runUnderstanding(db.deps, await emitIngested(db, a, a.member, a.devices.member));
  const member = await instancesByKey(db, a.member);
  expect([...member.values()]).toEqual([1, 1, 1]);
  expect((await brainRows(db, a.owner))["task_ledger"]).toEqual([]);
  expect((await brainRows(db, b.owner))["task_ledger"]).toEqual([]);

  // An event naming a member of another tenant reads nothing.
  const foreign = await emitIngested(db, a, b.owner, b.devices.owner);
  const r = await runUnderstanding(db.deps, foreign);
  expect(r.status).toBe("unknown_member");
  expect((await brainRows(db, b.owner))["task_ledger"]).toEqual([]);
});

t("CONSUME: drainUnderstanding processes pending events once and understandingWorkflow runs one event", async () => {
  const a = db.fx.a;
  await importInvoices(a.owner, a.devices.owner);
  await emitIngested(db, a, a.owner, a.devices.owner, 1);
  await emitIngested(db, a, a.owner, a.devices.owner, 2);
  await emitIngested(db, db.fx.b, db.fx.b.owner, db.fx.b.devices.owner, 1);
  const first = await drainUnderstanding(db.deps, { tenantId: a.tenantId });
  expect(first.map((x) => x.status)).toEqual(["updated", "updated"]);
  expect(await drainUnderstanding(db.deps, { tenantId: a.tenantId })).toEqual([]);

  const ev = await emitIngested(db, a, a.owner, a.devices.owner, 3);
  const steps: string[] = [];
  const rt = { step: async <T,>(name: string, fn: () => Promise<T>) => { steps.push(name); return fn(); } } as unknown as Parameters<ReturnType<typeof understandingWorkflow>>[0];
  const wf = understandingWorkflow(db.deps);
  await wf(rt, { tenant_id: a.tenantId, event_id: ev.eventId });
  expect(steps).toEqual(["understanding"]);
  expect((await runUnderstanding(db.deps, ev)).status).toBe("duplicate");
  // Tenant B's event is still pending: drains are per tenant.
  expect(await db.deps.capture.pendingEvents(db.fx.b.tenantId, 10)).toHaveLength(1);
});
