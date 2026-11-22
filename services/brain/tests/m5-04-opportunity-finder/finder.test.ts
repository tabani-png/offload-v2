import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { fixRules } from "../../src/opportunities/rules.ts";
import { collectFigures } from "../../src/records/figure.ts";
import { listOpportunityViews, resolveFigure } from "../../src/store/repository.ts";
import type { TenantContext } from "../../src/store/tenant.ts";
import { runUnderstanding } from "../../src/understanding/job.ts";
import { consumeDb, emitIngested, HAS_DB, insertCapture, resetRows, todayUtc, type ConsumeDb } from "../m5-01-understanding/db.ts";
import { invoiceImport } from "../m5-01-understanding/fixtures.ts";

const t = HAS_DB ? test : test.skip;
let db: ConsumeDb;

/** Monday, Tuesday and Wednesday of the ISO week two weeks before today (UTC): closed days of one week. */
function daysOfOneWeek(): string[] {
  const d = new Date(Date.parse(`${todayUtc()}T00:00:00Z`) - 14 * 86_400_000);
  const monday = d.getTime() - ((d.getUTCDay() + 6) % 7) * 86_400_000;
  return [0, 1, 2].map((i) => new Date(monday + i * 86_400_000).toISOString().slice(0, 10));
}

beforeAll(async () => {
  if (HAS_DB) db = await consumeDb();
}, 60_000);
afterAll(async () => {
  if (HAS_DB) await db.close();
});
beforeEach(async () => {
  if (HAS_DB) await resetRows(db);
});

const ctxOf = (memberId: string): TenantContext => ({ tenantId: db.fx.a.tenantId, memberId, principalId: "durable", tenantRole: "service" });

async function runImport(menuBar: boolean) {
  const a = db.fx.a;
  const fx = invoiceImport(daysOfOneWeek(), { perDay: 2, noise: true, menuBar });
  await insertCapture(db, a, a.owner, a.devices.owner, fx, todayUtc());
  const r = await runUnderstanding({ ...db.deps, fixRules: fixRules() }, await emitIngested(db, a, a.owner, a.devices.owner));
  expect(r.status).toBe("updated");
  return db.deps.runBrain(ctxOf(a.owner), (tx) => listOpportunityViews(tx));
}

t("FINDER: an import of a repeated invoice workflow yields a ranked opportunity with a proposed fix and noise yields none", async () => {
  const vs = await runImport(true);
  // One repeated workflow, six instances; the noise clips are single instances and get no fix.
  expect(vs).toHaveLength(1);
  const v = vs[0]!;
  expect(v.rank).toBe(1);
  expect(v.options.length).toBeGreaterThanOrEqual(1);
  expect(v.options[0]!.rule).toBe("email_to_records");
  const systems = new Set(v.options.flatMap((o) => o.steps.map((s) => s.system)));
  expect([...systems].sort()).toEqual(["app.ledgerly.example", "com.apple.mail", "com.microsoft.Excel"]);
  expect(v.score!.value).toBeGreaterThan(0);
  // A recording without a menu bar is cued from its text and gets a fix too.
  await resetRows(db);
  const cued = await runImport(false);
  expect(cued).toHaveLength(1);
  expect(cued[0]!.options.length).toBeGreaterThanOrEqual(1);
});

t("FINDER: figures of options resolve through figure_index", async () => {
  const [v] = await runImport(true);
  const figs = collectFigures({ options: v!.options.map((o) => o.figures) });
  expect(figs.length).toBe(4 * v!.options.length);
  for (const { figure } of figs) {
    const at = await db.deps.runBrain(ctxOf(db.fx.a.owner), (tx) => resolveFigure(tx, figure.id));
    expect(at?.record_kind).toBe("opportunity");
    expect(at?.record_key).toBe(`${v!.iso_week}/${v!.task_key}`);
  }
});

t("FINDER: without a workspace the fix rules are withheld and no opportunity is stored (review 1 finding 1)", async () => {
  const a = db.fx.a;
  await insertCapture(db, a, a.owner, a.devices.owner, invoiceImport(daysOfOneWeek(), { perDay: 2, noise: false, menuBar: true }), todayUtc());
  const capture = { ...db.deps.capture, workspaceOf: async () => null };
  const r = await runUnderstanding({ ...db.deps, capture, fixRules: fixRules() }, await emitIngested(db, a, a.owner, a.devices.owner));
  expect(r.status).toBe("updated");
  expect(await db.deps.runBrain(ctxOf(a.owner), (tx) => listOpportunityViews(tx))).toEqual([]);
  expect((await db.sql.unsafe(`SELECT count(*)::int AS n FROM ${db.schema}.day_records WHERE member_id = $1`, [a.owner]))[0].n).toBeGreaterThan(0);
});
