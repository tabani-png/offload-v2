// CONSUME, second part (review 1): concurrency, failures and the drain, the event range, pause, labels per member.
import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import type { RouteCall } from "../../src/models/router.ts";
import { defaultProfile } from "../../src/profile/profile.ts";
import * as repo from "../../src/store/repository.ts";
import { UNDERSTANDING_CONSUMER, type CaptureStore, type IngestedEvent } from "../../src/understanding/capture.ts";
import { drainUnderstanding, MAX_ATTEMPTS, runUnderstanding, type UnderstandingDeps } from "../../src/understanding/job.ts";
import { routerSpanLabeler } from "../../src/understanding/labeler.ts";
import { Barrier, consumeDb, daysAgo, emitIngested, HAS_DB, insertCapture, resetRows, todayUtc, type ConsumeDb } from "./db.ts";
import { invoiceImport, merge, NOISE, recordingObservations, rng, utc } from "./fixtures.ts";

const t = HAS_DB ? test : test.skip;
let db: ConsumeDb;
const DAYS = [daysAgo(12), daysAgo(11), daysAgo(10)];
const dayRange = (d: string) => ({ first_ts: `${d}T00:00:00Z`, last_ts: `${d}T23:59:00Z` });

beforeAll(async () => {
  if (HAS_DB) db = await consumeDb();
}, 60_000);
afterAll(async () => {
  if (HAS_DB) await db.close();
});
beforeEach(async () => {
  if (HAS_DB) await resetRows(db);
});

async function importInvoices(memberId = db.fx.a.owner, deviceId = db.fx.a.devices.owner, tenant = db.fx.a) {
  await insertCapture(db, tenant, memberId, deviceId, invoiceImport(DAYS, { perDay: 2, noise: true, menuBar: false }), todayUtc());
}
const delivery = async (ev: IngestedEvent) =>
  (await db.fx.admin.query("select attempts, delivered_at, last_error_code from outbox_deliveries where event_id = $1 and consumer = $2", [ev.eventId, UNDERSTANDING_CONSUMER])).rows[0];

t("CONSUME: two consumers of one event: one updates the model and the other does nothing", async () => {
  const a = db.fx.a;
  await importInvoices();
  const ev = await emitIngested(db, a, a.owner, a.devices.owner);
  db.gate.barrier = new Barrier(2);
  const before = db.brainCalls.n;
  const results = await Promise.all([runUnderstanding(db.deps, ev), runUnderstanding(db.deps, ev)]);
  expect(results.map((r) => r.status).filter((s) => s === "updated")).toHaveLength(1);
  expect(results.map((r) => r.status).filter((s) => s !== "updated")[0]).toMatch(/^(busy|duplicate)$/);
  // One profile read and one update.
  expect(db.brainCalls.n - before).toBe(2);
  expect((await delivery(ev)).attempts).toBe(1);
});

t("CONSUME: two events of one member update the model one after the other", async () => {
  const a = db.fx.a;
  await importInvoices();
  const first = await emitIngested(db, a, a.owner, a.devices.owner, 1, 1, dayRange(DAYS[0]!));
  const last = await emitIngested(db, a, a.owner, a.devices.owner, 2, 1, dayRange(DAYS[2]!));
  db.gate.barrier = new Barrier(2);
  const rs = await Promise.all([runUnderstanding(db.deps, first), runUnderstanding(db.deps, last)]);
  expect(rs.map((r) => r.status)).toEqual(["updated", "updated"]);
  const ledger = [...(await db.sql.unsafe(`SELECT first_seen_day::text AS f, last_seen_day::text AS l FROM ${db.schema}.task_ledger WHERE member_id = $1 AND task_kind LIKE 'email.%'`, [a.owner]))] as { f: string; l: string }[];
  expect(ledger).toEqual([{ f: DAYS[0]!, l: DAYS[2]! }]);
});

t("CONSUME: a failing event records its code, is rethrown, does not block the drain, and stops after the attempt cap", async () => {
  const a = db.fx.a;
  await importInvoices();
  const bad = await emitIngested(db, a, a.owner, a.devices.owner, 1);
  const good = await emitIngested(db, a, a.owner, a.devices.owner, 2);
  const base = db.deps.capture;
  let fails = 1;
  const capture: CaptureStore = {
    ...base,
    read: async (m, from, to) => {
      if (fails > 0) {
        fails--;
        throw Object.assign(new Error("boom"), { code: "read_failed" });
      }
      return base.read(m, from, to);
    },
  };
  const deps: UnderstandingDeps = { ...db.deps, capture };
  await expect(runUnderstanding(deps, bad)).rejects.toThrow("boom");
  expect(await delivery(bad)).toMatchObject({ attempts: 1, delivered_at: null, last_error_code: "read_failed" });
  // The drain records the failure of the oldest event and still processes the next one.
  fails = 1;
  const drained = await drainUnderstanding(deps, { tenantId: a.tenantId });
  expect(drained.map((r) => [r.eventId, r.status])).toEqual([[bad.eventId, "failed"], [good.eventId, "updated"]]);
  // An event that keeps failing stops being retried at the cap.
  fails = 1000;
  for (let i = 0; i < MAX_ATTEMPTS; i++) await drainUnderstanding(deps, { tenantId: a.tenantId });
  expect((await delivery(bad)).attempts).toBe(MAX_ATTEMPTS);
  expect(await db.deps.capture.pendingEvents(a.tenantId, 10)).toEqual([]);
  // The durable path keeps the cap too: an exhausted event is not run again (nothing is read).
  const before = fails;
  const capped = await runUnderstanding(deps, bad);
  expect([capped.status, capped.error]).toEqual(["failed", "attempts_exhausted"]);
  expect(fails).toBe(before);
  expect((await delivery(bad)).attempts).toBe(MAX_ATTEMPTS);
});

t("CONSUME: first_ts and last_ts in the event narrow the analysed days", async () => {
  const a = db.fx.a;
  await importInvoices();
  const r = await runUnderstanding(db.deps, await emitIngested(db, a, a.owner, a.devices.owner, 1, 1, dayRange(DAYS[1]!)));
  expect(r.days).toEqual([DAYS[1]!]);
});

t("CONSUME: with learning paused nothing is read or written and the event is delivered", async () => {
  const a = db.fx.a;
  await importInvoices();
  const ctx = { tenantId: a.tenantId, memberId: a.owner, principalId: a.owner, tenantRole: "owner" };
  await db.deps.runBrain(ctx, (tx) => repo.saveProfile(tx, { ok: true, profile: { ...defaultProfile(), learning_paused: true }, added: [], archived: [] }));
  let reads = 0;
  const deps: UnderstandingDeps = { ...db.deps, capture: { ...db.deps.capture, read: async (m, f, to) => { reads++; return db.deps.capture.read(m, f, to); } } };
  const ev = await emitIngested(db, a, a.owner, a.devices.owner);
  expect((await runUnderstanding(deps, ev)).status).toBe("paused");
  expect(reads).toBe(0);
  expect((await db.sql.unsafe(`SELECT count(*)::int AS n FROM ${db.schema}.task_ledger`))[0].n).toBe(0);
  expect((await delivery(ev)).delivered_at).not.toBeNull();
});

t("CONSUME: label route calls carry the event's tenant and member", async () => {
  const { a, b } = db.fx;
  const r = rng(77);
  const noise = () => merge(NOISE.slice(0, 2).map((seg, i) => recordingObservations({ start: utc(DAYS[0]!) + (10 + i) * 3_600_000, segments: [seg] }, r)));
  await insertCapture(db, a, a.owner, a.devices.owner, noise(), todayUtc());
  await insertCapture(db, b, b.owner, b.devices.owner, noise(), todayUtc());
  const calls: RouteCall[] = [];
  const route = async (call: RouteCall) => {
    calls.push(call);
    return { status: "needs_you" as const, call_id: "c", route: "label", reason: "monthly_budget_reached" as const, attempts: [] };
  };
  const deps: UnderstandingDeps = { ...db.deps, labelerFor: (m) => routerSpanLabeler(route, { tenant_id: m.tenantId, member_id: m.memberId }) };
  await runUnderstanding(deps, await emitIngested(db, a, a.owner, a.devices.owner));
  await runUnderstanding(deps, await emitIngested(db, b, b.owner, b.devices.owner));
  expect(calls.map((c) => [c.tenant_id, c.member_id])).toEqual([[a.tenantId, a.owner], [b.tenantId, b.owner]]);
});

t("CONSUME: a live batch uploaded days late is analysed on its own days", async () => {
  const a = db.fx.a;
  const late = daysAgo(3);
  // Live rows keep partition day = the UTC date of ts (DATA_MODEL section 5), here 3 days before the event.
  await insertCapture(db, a, a.owner, a.devices.owner, invoiceImport([late], { perDay: 2, noise: false, source: "live" }), late);
  const r = await runUnderstanding(db.deps, await emitIngested(db, a, a.owner, a.devices.owner));
  expect(r.status).toBe("updated");
  expect(r.days).toEqual([late]);
});

t("CONSUME: an event of a frozen member reads nothing", async () => {
  const a = db.fx.a;
  await insertCapture(db, a, a.member, a.devices.member, invoiceImport(DAYS, { perDay: 1, noise: false }), todayUtc());
  await db.fx.admin.query("update members set state = 'frozen' where id = $1", [a.member]);
  try {
    expect((await runUnderstanding(db.deps, await emitIngested(db, a, a.member, a.devices.member))).status).toBe("unknown_member");
  } finally {
    await db.fx.admin.query("update members set state = 'active' where id = $1", [a.member]);
  }
});

t("CONSUME: the analysed days are the member's timezone days", async () => {
  const a = db.fx.a;
  const ctx = { tenantId: a.tenantId, memberId: a.owner, principalId: a.owner, tenantRole: "owner" };
  await db.deps.runBrain(ctx, (tx) => repo.saveProfile(tx, { ok: true, profile: { ...defaultProfile(), timezone: "America/New_York" }, added: [], archived: [] }));
  const r2 = rng(78);
  // 02:00 UTC on DAYS[1] is 21:00 on DAYS[0] in New York.
  await insertCapture(db, a, a.owner, a.devices.owner, recordingObservations({ start: Date.parse(`${DAYS[1]}T02:00:00Z`), segments: [NOISE[0]!] }, r2), todayUtc());
  const r = await runUnderstanding(db.deps, await emitIngested(db, a, a.owner, a.devices.owner));
  expect(r.status).toBe("updated");
  expect(r.days).toEqual([DAYS[0]!]);
});

t("CONSUME: an import older than 31 days is analysed on its own days even when the member has live rows", async () => {
  const a = db.fx.a;
  // Recordings on 42 and 40 days ago; nothing on the day between.
  const old = [daysAgo(42), daysAgo(40)];
  const yesterday = daysAgo(1);
  // Onboarding: last month's recordings are imported today while live capture has started.
  await insertCapture(db, a, a.owner, a.devices.owner, invoiceImport(old, { perDay: 2, noise: false, menuBar: false }), todayUtc());
  const r2 = rng(79);
  await insertCapture(db, a, a.owner, a.devices.owner, recordingObservations({ start: Date.parse(`${yesterday}T10:00:00Z`), source: "live", segments: [NOISE[1]!] }, r2), yesterday);
  const r = await runUnderstanding(db.deps, await emitIngested(db, a, a.owner, a.devices.owner));
  expect(r.status).toBe("updated");
  // Only days that hold rows are analysed: the import's two days and the live day, not the empty day 41 days ago.
  expect(r.days).toEqual([...old, yesterday]);
  const byKey = [...(await db.sql.unsafe(`SELECT task_key, count(*)::int AS n FROM ${db.schema}.episodes WHERE member_id = $1 AND kind = 'task_instance' GROUP BY task_key`, [a.owner]))] as { n: number }[];
  expect(byKey.map((x) => x.n).filter((n) => n > 1)).toEqual([4]);
});

t("CONSUME: an import spanning 40 days is analysed on every day that holds rows", async () => {
  const a = db.fx.a;
  const span = [daysAgo(45), daysAgo(25), daysAgo(5)];
  await insertCapture(db, a, a.owner, a.devices.owner, invoiceImport(span, { perDay: 2, noise: false, menuBar: false }), todayUtc());
  const r = await runUnderstanding(db.deps, await emitIngested(db, a, a.owner, a.devices.owner));
  expect(r.status).toBe("updated");
  expect(r.days).toEqual(span);
  const byKey = [...(await db.sql.unsafe(`SELECT count(*)::int AS n FROM ${db.schema}.episodes WHERE member_id = $1 AND kind = 'task_instance' GROUP BY task_key`, [a.owner]))] as { n: number }[];
  expect(byKey.map((x) => x.n)).toEqual([6]);
});

t("CONSUME: an event range from first_ts to last_ts over an old import and live rows covers both", async () => {
  const a = db.fx.a;
  const old = [daysAgo(42), daysAgo(40)];
  const yesterday = daysAgo(1);
  await insertCapture(db, a, a.owner, a.devices.owner, invoiceImport(old, { perDay: 2, noise: false, menuBar: false }), todayUtc());
  await insertCapture(db, a, a.owner, a.devices.owner, recordingObservations({ start: Date.parse(`${yesterday}T10:00:00Z`), source: "live", segments: [NOISE[1]!] }, rng(80)), yesterday);
  const r = await runUnderstanding(db.deps, await emitIngested(db, a, a.owner, a.devices.owner, 1, 1, { first_ts: `${old[0]}T00:00:00Z`, last_ts: `${yesterday}T23:59:00Z` }));
  expect(r.days).toEqual([...old, yesterday]);
});
