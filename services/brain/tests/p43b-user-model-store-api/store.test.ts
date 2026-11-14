// Storage rules: idempotent merge, expired not deleted, the leak guard, figure_index, source purged.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { collectFigures } from "../../src/records/figure.ts";
import { getDayRecord, listOpportunities, loadPropositions, markSourcePurged, resolveFigure, saveEpisodes, saveLedger } from "../../src/store/repository.ts";
import { applyProfilePatch } from "../../src/profile/profile.ts";
import { getProfile, saveProfile } from "../../src/store/repository.ts";
import { runMemberUpdate } from "../../src/store/job.ts";
import { MEMBER_ISOLATED_TABLES } from "../../src/store/migrate.ts";
import { fixtureWeek, mondayNoonAfter, MONDAYS, SEED } from "../fixtures/window.ts";
import { dumpAll, estimateFor, HAS_DB, seedFourWeeks, testDb, type TestDb } from "./db.ts";

let db: TestDb;
beforeAll(async () => {
  if (!HAS_DB) return;
  db = await testDb("store");
  await seedFourWeeks(db, db.A1, db.workspaceA);
});
afterAll(async () => {
  if (HAS_DB) await db.cleanup();
});

describe.skipIf(!HAS_DB)("p43b storage rules", () => {
  test("MERGE: the update job run twice with the same window leaves identical rows", async () => {
    const fx = fixtureWeek(MONDAYS[0], { seed: SEED });
    const now = mondayNoonAfter(MONDAYS[0]);
    const run = () => db.run(db.A2, (tx) => runMemberUpdate(tx, { window: fx.window, now, workspaceId: db.workspaceA, estimateFor }));
    await run();
    const first = await dumpAll(db, MEMBER_ISOLATED_TABLES);
    expect(first["propositions"]!.length).toBeGreaterThan(0);
    expect(first["opportunities"]!.length).toBeGreaterThan(0);
    await run();
    expect(await dumpAll(db, MEMBER_ISOLATED_TABLES)).toEqual(first);
  });

  test("INVALIDATE: an ended proposition stays as a row with invalid_at and expired_at; the pattern's return starts version 2", async () => {
    const props = await db.run(db.A1, (tx) => loadPropositions(tx));
    const calls = props.filter((p) => p.kind === "repeats" && p.evidence.subject.name === "Calls in zoom").sort((a, b) => a.version - b.version);
    expect(calls.map((p) => p.version)).toEqual([1, 2]);
    expect(calls[0]!.invalidAt).not.toBeNull();
    expect(calls[0]!.expiredAt).toBe(mondayNoonAfter(MONDAYS[2]));
    expect(calls[0]!.revisionGroup).toBe(calls[1]!.revisionGroup);
    expect(calls[1]!.invalidAt).toBeNull();
  });

  test("INVALIDATE: offload_app cannot DELETE propositions, records or answers", async () => {
    for (const t of ["propositions", "day_records", "week_records", "task_ledger", "episodes", "review_answers", "profiles", "goals"]) {
      let err = "";
      try {
        await db.run(db.A1, (tx) => tx.unsafe(`DELETE FROM ${t}`));
      } catch (e) {
        err = String(e);
      }
      expect({ t, err: err.includes("permission denied") }).toEqual({ t, err: true });
    }
    const n = await db.run(db.A1, async (tx) => ((await tx.unsafe("SELECT count(*)::int AS n FROM propositions")) as Array<{ n: number }>)[0]!.n);
    expect(n).toBeGreaterThan(0);
  });

  test("STORE: a write carrying an email address or a URL is refused and nothing is stored", async () => {
    const ep = { id: "ep_leak", kind: "task_instance" as const, day: "2026-11-03", started_at: "2026-11-03T09:00:00.000Z", ended_at: "2026-11-03T09:05:00.000Z", minutes: 5, apps: ["com.apple.mail"], task_key: null, name: "Mail dana@fund.example", evidence: [], source_purged_at: null };
    await expect(db.run(db.B1, (tx) => saveEpisodes(tx, [ep]))).rejects.toThrow(/email|URL/);
    const entry = { taskKey: "k_0123456789ab", signatures: ["0123456789abcdef"], taskKind: "x.y", appBundleId: "a", host: "", nameWords: [], name: "see https://x.example/a", centroid: null, firstSeenDay: "2026-11-03", lastSeenDay: "2026-11-03" };
    await expect(db.run(db.B1, (tx) => saveLedger(tx, [entry]))).rejects.toThrow(/email|URL/);
    const n = await db.sql.unsafe(`SELECT (SELECT count(*) FROM ${db.schema}.episodes WHERE member_id = $1) + (SELECT count(*) FROM ${db.schema}.task_ledger WHERE member_id = $1) AS n`, [db.B1.memberId]);
    expect(Number(n[0].n)).toBe(0);
  });

  test("STORE: every figure in a saved record or opportunity resolves through figure_index", async () => {
    const day = (await db.run(db.A1, (tx) => getDayRecord(tx, "2026-11-04")))!;
    const figs = collectFigures(day);
    expect(figs.length).toBeGreaterThan(5);
    const at = (rec: unknown, pointer: string) => pointer.split("/").slice(1).reduce((v: any, k) => v?.[k.replaceAll("~1", "/").replaceAll("~0", "~")], rec);
    let own = 0;
    for (const { pointer, figure } of figs) {
      const hit = await db.run(db.A1, (tx) => resolveFigure(tx, figure.id));
      expect(hit).not.toBeNull();
      expect(hit!.record_kind).toBe("day");
      // Two figures with the same content share an id; the index points at one of them.
      const rec = hit!.record_key === day.day ? day : (await db.run(db.A1, (tx) => getDayRecord(tx, hit!.record_key)))!;
      expect(at(rec, hit!.json_pointer)?.id).toBe(figure.id);
      if (hit!.record_key === day.day && hit!.json_pointer === pointer) own += 1;
    }
    expect(own).toBeGreaterThan(figs.length / 2);
    const opp = (await db.run(db.A1, (tx) => listOpportunities(tx, "2026-W45")))[0]!;
    const hit = await db.run(db.A1, (tx) => resolveFigure(tx, opp.factors.persistence.id));
    expect(hit?.record_kind).toBe("opportunity");
    expect(await db.run(db.A2, (tx) => resolveFigure(tx, day.totals.active_minutes.id))).toBeNull();
  });

  test("STORE: markSourcePurged keeps every value, sets source_purged_at and re-indexes the figures", async () => {
    const at = "2026-12-15T00:00:00.000Z";
    const before = (await db.run(db.A1, (tx) => getDayRecord(tx, "2026-10-13")))!;
    await db.run(db.A1, (tx) => markSourcePurged(tx, "2026-10-13", at));
    const after = (await db.run(db.A1, (tx) => getDayRecord(tx, "2026-10-13")))!;
    expect(after.source_purged_at).toBe(at);
    const b = collectFigures(before);
    const a = collectFigures(after);
    expect(a.map((x) => [x.pointer, x.figure.value])).toEqual(b.map((x) => [x.pointer, x.figure.value]));
    for (const { figure } of a) expect(figure.source_purged_at).toBe(at);
    expect(await db.run(db.A1, (tx) => resolveFigure(tx, after.totals.active_minutes.id))).not.toBeNull();
    expect(await db.run(db.A1, (tx) => resolveFigure(tx, before.totals.active_minutes.id))).toBeNull();
    const eps = await db.sql.unsafe(`SELECT count(*)::int AS n FROM ${db.schema}.episodes WHERE member_id = $1 AND day = '2026-10-13' AND source_purged_at IS NULL`, [db.A1.memberId]);
    expect(eps[0].n).toBe(0);
  });

  test("STORE: a figure shared by two records still resolves after one of them is re-indexed", async () => {
    const sat = (await db.run(db.A1, (tx) => getDayRecord(tx, "2026-10-17")))!;
    const sun = (await db.run(db.A1, (tx) => getDayRecord(tx, "2026-10-18")))!;
    const id = sat.totals.meeting_minutes.id;
    expect(sun.totals.meeting_minutes.id).toBe(id);
    await db.run(db.A1, (tx) => markSourcePurged(tx, "2026-10-17", "2026-12-15T00:00:00.000Z"));
    const hit = await db.run(db.A1, (tx) => resolveFigure(tx, id));
    expect(hit).toEqual({ record_kind: "day", record_key: "2026-10-18", json_pointer: "/totals/meeting_minutes" });
  });

  test("STORE: the job refuses a window whose timezone is not the profile's, and stores nothing", async () => {
    await db.run(db.B1, async (tx) => {
      const r = applyProfilePatch(await getProfile(tx), { timezone: "Asia/Karachi" }, Date.UTC(2026, 9, 1));
      if (!r.ok) throw new Error(r.message);
      await saveProfile(tx, r);
    });
    const fx = fixtureWeek(MONDAYS[0], { seed: SEED });
    expect(fx.window.timezone).toBe("UTC");
    const err = await db.run(db.B1, (tx) => runMemberUpdate(tx, { window: fx.window, now: mondayNoonAfter(MONDAYS[0]), workspaceId: db.workspaceB, estimateFor })).then(() => null, (e: unknown) => e);
    expect(String(err)).toMatch(/timezone/);
    // Retrying the same window can never succeed: the caller must rebuild it in the profile's timezone.
    expect(err).toMatchObject({ code: "timezone_mismatch", retryable: false });
    const n = await db.sql.unsafe(`SELECT count(*)::int AS n FROM ${db.schema}.day_records WHERE member_id = $1`, [db.B1.memberId]);
    expect(n[0].n).toBe(0);
    const ok = fixtureWeek(MONDAYS[0], { seed: SEED, timezone: "Asia/Karachi" });
    await db.run(db.B1, (tx) => runMemberUpdate(tx, { window: ok.window, now: mondayNoonAfter(MONDAYS[0]), workspaceId: db.workspaceB, estimateFor }));
    const m = await db.sql.unsafe(`SELECT count(*)::int AS n FROM ${db.schema}.day_records WHERE member_id = $1`, [db.B1.memberId]);
    expect(m[0].n).toBeGreaterThan(0);
  });
});
