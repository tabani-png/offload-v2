import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { fixRules, type FixRules } from "../../src/opportunities/rules.ts";
import { runMemberUpdate } from "../../src/store/job.ts";
import { getOpportunityView, listOpportunityViews, listWeekEpisodes } from "../../src/store/repository.ts";
import { fixtureWeek, mondayNoonAfter, MONDAYS, SEED, WEEKS } from "../fixtures/window.ts";
import { dump, HAS_DB, testDb, type TestDb } from "./db.ts";

const t = HAS_DB ? test : test.skip;
let db: TestDb;
const TABLES = ["opportunities", "fixes", "figure_index", "episodes"] as const;

beforeAll(async () => {
  if (HAS_DB) db = await testDb();
});
afterAll(async () => {
  if (HAS_DB) await db.cleanup();
});
beforeEach(async () => {
  if (!HAS_DB) return;
  for (const x of ["fixes", "opportunities", "figure_index", "episodes", "day_records", "week_records", "task_ledger", "propositions", "month_records", "quarter_records"]) await db.sql.unsafe(`DELETE FROM ${db.schema}.${x}`);
});

const week = fixtureWeek(MONDAYS[0], { seed: SEED });
const now = mondayNoonAfter(MONDAYS[0]);
const update = (rules: FixRules, ctx = db.A1) => db.run(ctx, (tx) => runMemberUpdate(tx, { window: week.window, now, workspaceId: db.workspace, fixRules: rules }));
const views = (ctx = db.A1) => db.run(ctx, (tx) => listOpportunityViews(tx, { isoWeek: WEEKS[0] }));
const latestViews = () => db.run(db.A1, (tx) => listOpportunityViews(tx));

t("PERSIST: the update job with the fix rules stores ranked opportunities, their options and episode hosts", async () => {
  const r = await update(fixRules());
  expect(r.ranked).toBe(3);
  const vs = await views();
  const titles = vs.map((v) => v.title);
  expect(titles).toContain("Outreach emails");
  for (const no of ["Calls in zoom", "Review pull requests", "Slack replies"]) expect(titles).not.toContain(no);
  for (const v of vs) {
    expect(v.source).toBe("finder");
    expect(v.state).toBe("open");
    expect(v.score?.unit).toBe("score");
    expect(v.options.length).toBeGreaterThanOrEqual(1);
    expect(v.options.map((o) => o.option_no)).toEqual(v.options.map((_, i) => i + 1));
    expect(v.options[0]!.recommended).toBe(!v.leave_alone_first);
    // The ranked saving is option 1's saving.
    expect(v.factors.weekly_hours_saved!.value).toBe(v.options[0]!.figures.weekly_hours_saved.value);
    for (const o of v.options) expect(o.id).toMatch(/^[0-9a-f-]{36}$/);
  }
  const outreach = vs.find((v) => v.title === "Outreach emails")!;
  expect(outreach.options[0]!.kind).toBe("setup_change");
  expect(outreach.options[0]!.rule).toBe("email_triage");
  const rows = await dump(db, db.A1.memberId, ["fixes"]);
  expect(rows["fixes"]!.length).toBe(vs.reduce((n, v) => n + v.options.length, 0));
  const hosts = await db.sql.unsafe(`SELECT DISTINCT hosts FROM ${db.schema}.episodes WHERE member_id = $1 AND name = 'Outreach emails' AND kind = 'task_instance'`, [db.A1.memberId]);
  expect([...hosts].map((h) => (h as { hosts: string[] }).hosts)).toEqual([["mail.google.com"]]);

  // An episode row left behind by a re-analysed day (not in day_records.episode_ids) is not read (review 1 finding 1).
  const days = (await db.sql.unsafe(`SELECT day::text AS day FROM ${db.schema}.day_records WHERE member_id = $1 ORDER BY day`, [db.A1.memberId])).map((r: any) => r.day as string);
  await db.sql.unsafe(
    `INSERT INTO ${db.schema}.episodes (tenant_id, member_id, id, kind, day, started_at, ended_at, minutes, apps, hosts, task_key, name, evidence)
     VALUES ($1, $2, 'ep_stale', 'task_instance', $3::date, $4, $4, 5, '{com.google.Chrome}', '{stale.example}', $5, 'Outreach emails', '{}')`,
    [db.A1.tenantId, db.A1.memberId, days[0], `${days[0]}T10:00:00Z`, outreach.task_key],
  );
  const read = await db.run(db.A1, (tx) => listWeekEpisodes(tx, days[0]!, days[days.length - 1]!));
  expect(read.length).toBeGreaterThan(0);
  expect(read.map((e) => e.id)).not.toContain("ep_stale");
  await update(fixRules());
  const again = (await views()).find((v) => v.title === "Outreach emails")!;
  expect(again.options.flatMap((o) => o.steps.map((s) => s.system))).not.toContain("stale.example");
});

t("PERSIST: a re-run leaves identical rows and a task leaving the top 5 loses its open opportunity and options", async () => {
  const rules = fixRules();
  await update(rules);
  const first = await dump(db, db.A1.memberId, TABLES);
  await update(rules);
  expect(await dump(db, db.A1.memberId, TABLES)).toEqual(first);
  const outreach = (await views()).find((v) => v.title === "Outreach emails")!;
  // Two options before; one after a re-run that proposes one: option 2's row is gone (review 1 finding 1).
  expect(outreach.options).toHaveLength(2);
  const one: FixRules = { propose: (e) => { const p = rules.propose(e); return p === null ? null : { ...p, options: p.options.slice(0, 1) }; } };
  await update(one);
  const fixCount = await db.sql.unsafe(`SELECT count(*)::int AS n FROM ${db.schema}.fixes WHERE opportunity_id = $1`, [outreach.id]);
  expect(fixCount[0].n).toBe(1);
  const without: FixRules = { propose: (e) => (e.name === "Outreach emails" ? null : rules.propose(e)) };
  expect((await update(without)).ranked).toBe(2);
  expect((await views()).map((v) => v.title)).not.toContain("Outreach emails");
  const left = await db.sql.unsafe(`SELECT count(*)::int AS n FROM ${db.schema}.fixes WHERE opportunity_id = $1`, [outreach.id]);
  expect(left[0].n).toBe(0);
  const figs = await db.sql.unsafe(`SELECT count(*)::int AS n FROM ${db.schema}.figure_index WHERE record_kind = 'opportunity' AND record_key = $1`, [`${WEEKS[0]}/${outreach.task_key}`]);
  expect(figs[0].n).toBe(0);
});

t("PERSIST: options of a chosen opportunity are not touched and members read only their own", async () => {
  const rules = fixRules();
  await update(rules);
  const vs = await views();
  // One opportunity moved on to `chosen`; another still `open` but with an option already picked.
  const chosen = vs[0]!;
  const picked = vs[1]!;
  await db.sql.unsafe(`UPDATE ${db.schema}.opportunities SET state = 'chosen' WHERE id = $1`, [chosen.id]);
  await db.sql.unsafe(`UPDATE ${db.schema}.fixes SET chosen_at = now() WHERE opportunity_id = $1 AND option_no = 1`, [picked.id]);
  const fixRows = (id: string) => db.sql.unsafe(`SELECT to_jsonb(x) AS row FROM ${db.schema}.fixes x WHERE opportunity_id = $1 ORDER BY 1`, [id]);
  const before = [await fixRows(chosen.id), await fixRows(picked.id)];
  const renamed: FixRules = { propose: (e) => { const p = rules.propose(e); return p === null ? null : { ...p, options: p.options.map((o) => ({ ...o, title: `${o.title} again` })) }; } };
  await update(renamed);
  expect([await fixRows(chosen.id), await fixRows(picked.id)]).toEqual(before);
  const after = await views();
  const others = after.filter((x) => x.id !== chosen.id && x.id !== picked.id);
  expect(others.length).toBeGreaterThan(0);
  for (const v of others) for (const o of v.options) expect(o.title.endsWith(" again")).toBe(true);
  expect(after.find((x) => x.id === picked.id)!.options[0]!.chosen_at).not.toBeNull();
  // The member wall.
  expect(await views(db.A2)).toEqual([]);
  expect(await db.run(db.A2, (tx) => getOpportunityView(tx, chosen.id))).toBeNull();
  const mine = await db.run(db.A1, (tx) => getOpportunityView(tx, chosen.id));
  expect(mine?.options.length).toBe(chosen.options.length);
  expect(await db.run(db.A2, async (tx) => ((await tx.unsafe("SELECT count(*)::int AS n FROM fixes")) as Array<{ n: number }>)[0]!.n)).toBe(0);
});

t("PERSIST: without a week the latest week with an opportunity is read, and a state filter applies within it (review 1 finding 5)", async () => {
  const rules = fixRules();
  await update(rules);
  const next = fixtureWeek(MONDAYS[1], { seed: SEED + 1 });
  await db.run(db.A1, (tx) => runMemberUpdate(tx, { window: next.window, now: mondayNoonAfter(MONDAYS[1]), workspaceId: db.workspace, fixRules: rules }));
  const latest = await latestViews();
  expect(latest.length).toBeGreaterThan(0);
  expect(new Set(latest.map((v) => v.iso_week))).toEqual(new Set([WEEKS[1]]));
  const older = await db.run(db.A1, (tx) => listOpportunityViews(tx, { isoWeek: WEEKS[0] }));
  expect(new Set(older.map((v) => v.iso_week))).toEqual(new Set([WEEKS[0]]));
  await db.sql.unsafe(`UPDATE ${db.schema}.opportunities SET state = 'not_now' WHERE id = $1`, [latest[0]!.id]);
  const open = await db.run(db.A1, (tx) => listOpportunityViews(tx, { state: "open" }));
  expect(open.map((v) => v.id)).toEqual(latest.slice(1).map((v) => v.id));
});

t("PERSIST: each option carries its saving as estimate, and an opportunity its description and goal, in the shapes the Mac decodes (review 2 finding 1)", async () => {
  await update(fixRules());
  const vs = await views();
  expect(vs.length).toBeGreaterThan(0);
  // The JSON the API sends: FixOption { id, option_no, title, detail, recommended, estimate, kind } (BuildsModels.swift).
  const raw = JSON.parse(JSON.stringify(vs)) as Array<Record<string, any>>;
  for (const v of raw) {
    expect(v["description"]).toBe("");
    expect(v["goal"]).toBeNull();
    for (const o of v["options"]) {
      for (const k of ["id", "option_no", "title", "detail", "recommended", "kind"]) expect(o[k]).toBeDefined();
      expect(o["estimate"]).toEqual(o["figures"]["weekly_hours_saved"]);
      expect(o["estimate"]["unit"]).toBe("hours_per_week");
    }
  }
  // A goal named on the opportunity comes back as { id, text } (OpportunityGoal).
  const g = "g_0123456789";
  await db.sql.unsafe(`INSERT INTO ${db.schema}.goals (tenant_id, member_id, id, text, created_at) VALUES ($1, $2, $3, 'Close the books faster', now())`, [db.A1.tenantId, db.A1.memberId, g]);
  await db.sql.unsafe(`UPDATE ${db.schema}.opportunities SET goal_id = $1 WHERE id = $2`, [g, vs[0]!.id]);
  const one = JSON.parse(JSON.stringify(await db.run(db.A1, (tx) => getOpportunityView(tx, vs[0]!.id))));
  expect(one.goal).toEqual({ id: g, text: "Close the books faster" });
  expect(one.goal_id).toBe(g);
  expect(one.options[0].estimate).toEqual(one.options[0].figures.weekly_hours_saved);
});

t("PERSIST: a re-ranked opportunity whose estimate gives no option keeps no stale option (review 2 finding 2)", async () => {
  const half = (fixKind: string) => (task: { minutes: { value: number } }) =>
    task.minutes.value <= 0 ? null : { fixKind, weeklyHoursSaved: Math.round((task.minutes.value / 60) * 50) / 100, setupHours: 3, ruleConfidence: 0.7, workKind: "email" as const };
  const run = (fixKind: string) => db.run(db.A1, (tx) => runMemberUpdate(tx, { window: week.window, now, workspaceId: db.workspace, estimateFor: half(fixKind) }));
  await run("agent_workflow");
  const before = await views();
  expect(before.length).toBeGreaterThan(0);
  for (const v of before) expect(v.options.map((o) => o.kind)).toEqual(["agent_workflow"]);
  // Same numbers, but a kind no option row can carry: the task stays ranked and its old option goes.
  await run("leave_alone");
  const after = await views();
  expect(after.map((v) => v.id)).toEqual(before.map((v) => v.id));
  for (const v of after) expect(v.options).toEqual([]);
  expect((await dump(db, db.A1.memberId, ["fixes"]))["fixes"]).toEqual([]);
});

t("PERSIST: an open opportunity with a picked option is kept when it leaves the top 5 (review 2 finding 3)", async () => {
  const rules = fixRules();
  await update(rules);
  const outreach = (await views()).find((v) => v.title === "Outreach emails")!;
  await db.sql.unsafe(`UPDATE ${db.schema}.fixes SET chosen_at = now() WHERE opportunity_id = $1 AND option_no = 1`, [outreach.id]);
  await update({ propose: (e) => (e.name === "Outreach emails" ? null : rules.propose(e)) });
  const kept = await db.run(db.A1, (tx) => getOpportunityView(tx, outreach.id));
  expect(kept).not.toBeNull();
  expect(kept!.rank).toBeNull();
  expect(kept!.options[0]!.chosen_at).not.toBeNull();
  expect(kept!.options.length).toBe(outreach.options.length);
});
