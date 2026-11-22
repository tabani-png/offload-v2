// Repository for the user model's R-model tables. Every function runs inside RunInTenant: tenant_id and member_id
// are written from the transaction's app.tenant_id / app.member_id, never passed in. Rows are never deleted here
// (except figure_index rows of a re-saved record, open finder opportunities that left the top 5 and the options of an
// open opportunity, which are replaced when it is ranked again). A write whose
// text holds an email address or a URL is refused (old assertDerivedOnly, kept as a second line behind names.ts).
import type { RankedOpportunity } from "../opportunities/score.ts";
import { LEAVE_ALONE_BELOW_HOURS } from "../opportunities/rules.ts";
import type { FixOption } from "../opportunities/types.ts";
import type { Figure } from "../records/figure.ts";
import { defaultProfile, type Goal, type PatchResult, type Profile } from "../profile/profile.ts";
import { addWeeks, weekDays } from "../records/dates.ts";
import type { DayRecord, Episode } from "../records/day-record.ts";
import { collectFigures, withSourcePurged } from "../records/figure.ts";
import type { RollupRecord } from "../records/rollup.ts";
import type { WeekRecord } from "../records/week-record.ts";
import type { Answer, ReviewAnswer } from "../review/answers.ts";
import type { ReviewOpportunity } from "../review/week-review.ts";
import type { LedgerEntry } from "../user-model/ledger.ts";
import { hasAnyLink, hasLeak } from "../user-model/names.ts";
import type { Proposition } from "../user-model/types.ts";
import { uuidv7 } from "./ids.ts";
import type { Tx } from "./tenant.ts";

/** A write would store an email address or a URL. */
export class LeakError extends Error {
  readonly code = "leak_detected";
}

export interface StoredGoal extends Goal {
  embedding: number[] | null;
}

export type StoredOpportunity = ReviewOpportunity & { id: string; score: number; goal_id: string | null; factors: RankedOpportunity["factors"] };

type Row = Record<string, any>;
const TID = "current_setting('app.tenant_id')::uuid";
const MID = "current_setting('app.member_id')::uuid";
const OWN = `tenant_id = ${TID} AND member_id = ${MID}`;
const iso = (v: unknown): string | null => (v === null || v === undefined ? null : v instanceof Date ? v.toISOString() : new Date(String(v)).toISOString());
const json = (v: unknown) => JSON.stringify(v);

function guard(label: string, value: unknown): void {
  if (hasLeak(JSON.stringify(value))) throw new LeakError(`${label} would store an email address or a URL; refused`);
}

async function rows(tx: Tx, q: string, params: unknown[] = []): Promise<Row[]> {
  return [...((await tx.unsafe(q, params)) as Row[])];
}

/** Re-indexes the figures of one record in figure_index (one row per record holding the figure). */
async function indexFigures(tx: Tx, kind: string, key: string, record: unknown): Promise<void> {
  const figs = collectFigures(record);
  await tx.unsafe(`DELETE FROM figure_index WHERE ${OWN} AND record_kind = $1 AND record_key = $2 AND NOT (figure_id = ANY($3::text[]))`, [kind, key, figs.map((f) => f.figure.id)]);
  for (const { pointer, figure } of figs) {
    await tx.unsafe(
      `INSERT INTO figure_index (tenant_id, member_id, figure_id, record_kind, record_key, json_pointer) VALUES (${TID}, ${MID}, $1, $2, $3, $4) ON CONFLICT (tenant_id, member_id, figure_id, record_kind, record_key) DO NOTHING`,
      [figure.id, kind, key, pointer],
    );
  }
}

// ---------- profile and goals ----------

const goalOf = (r: Row): StoredGoal => ({ id: r["id"], text: r["text"], horizon: "90d", created_at: iso(r["created_at"])!, archived_at: iso(r["archived_at"]), embedding: r["embedding"] ?? null });

export async function listGoals(tx: Tx, opts: { archived?: boolean } = {}): Promise<StoredGoal[]> {
  const where = opts.archived === true ? "" : " AND archived_at IS NULL";
  return (await rows(tx, `SELECT id, text, created_at, archived_at, embedding FROM goals WHERE ${OWN}${where} ORDER BY archived_at NULLS FIRST, position, created_at, id`)).map(goalOf);
}

export async function getProfile(tx: Tx): Promise<Profile> {
  const goals = (await listGoals(tx)).map(({ embedding: _e, ...g }) => g);
  const [r] = await rows(tx, `SELECT * FROM profiles WHERE ${OWN}`);
  if (r === undefined) return { ...defaultProfile(), goals };
  return {
    version: r["version"], role: r["role"], industry: r["industry"], goals, drains: r["drains"], schedule: r["schedule"], timezone: r["timezone"],
    review_slot: r["review_slot"], autonomy: r["autonomy"], own_name_to_models: r["own_name_to_models"], keyframes_to_cloud: r["keyframes_to_cloud"],
    learning_paused: r["learning_paused"], updated_at: iso(r["updated_at"]),
  };
}

/** Serialises profile edits of one member (read-modify-write in PATCH). */
export async function lockProfile(tx: Tx): Promise<void> {
  await tx.unsafe("SELECT pg_advisory_xact_lock(hashtextextended('profile:' || current_setting('app.member_id'), 0))");
}

export async function saveProfile(tx: Tx, r: Extract<PatchResult, { ok: true }>): Promise<Profile> {
  const p = r.profile;
  guard("profile", p);
  await tx.unsafe(
    `INSERT INTO profiles (tenant_id, member_id, version, role, industry, drains, schedule, timezone, review_slot, autonomy, own_name_to_models, keyframes_to_cloud, learning_paused, updated_at)
     VALUES (${TID}, ${MID}, $1, $2, $3, $4, $5::text::jsonb, $6, $7::text::jsonb, $8, $9, $10, $11, $12)
     ON CONFLICT (tenant_id, member_id) DO UPDATE SET version = EXCLUDED.version, role = EXCLUDED.role, industry = EXCLUDED.industry,
       drains = EXCLUDED.drains, schedule = EXCLUDED.schedule, timezone = EXCLUDED.timezone, review_slot = EXCLUDED.review_slot,
       autonomy = EXCLUDED.autonomy, own_name_to_models = EXCLUDED.own_name_to_models, keyframes_to_cloud = EXCLUDED.keyframes_to_cloud,
       learning_paused = EXCLUDED.learning_paused, updated_at = EXCLUDED.updated_at`,
    [p.version, p.role, p.industry, p.drains, json(p.schedule), p.timezone, json(p.review_slot), p.autonomy, p.own_name_to_models, p.keyframes_to_cloud, p.learning_paused, p.updated_at],
  );
  for (const g of r.archived) await tx.unsafe(`UPDATE goals SET archived_at = $2 WHERE ${OWN} AND id = $1 AND archived_at IS NULL`, [g.id, g.archived_at]);
  for (const g of r.added) {
    await tx.unsafe(`INSERT INTO goals (tenant_id, member_id, id, text, horizon, created_at) VALUES (${TID}, ${MID}, $1, $2, $3, $4)`, [g.id, g.text, g.horizon, g.created_at]);
  }
  for (const [i, g] of p.goals.entries()) await tx.unsafe(`UPDATE goals SET position = $2 WHERE ${OWN} AND id = $1`, [g.id, i]);
  return getProfile(tx);
}

// ---------- task ledger ----------

export async function loadLedger(tx: Tx): Promise<LedgerEntry[]> {
  return (await rows(tx, `SELECT task_key, signatures, task_kind, app_bundle_id, host, name_words, name, centroid, first_seen_day::text AS first_seen_day, last_seen_day::text AS last_seen_day FROM task_ledger WHERE ${OWN} ORDER BY task_key`)).map((r) => ({
    taskKey: r["task_key"], signatures: r["signatures"], taskKind: r["task_kind"], appBundleId: r["app_bundle_id"], host: r["host"], nameWords: r["name_words"],
    name: r["name"], centroid: r["centroid"] ?? null, firstSeenDay: r["first_seen_day"], lastSeenDay: r["last_seen_day"],
  }));
}

export async function saveLedger(tx: Tx, entries: readonly LedgerEntry[]): Promise<void> {
  guard("task ledger", entries.map(({ centroid: _c, ...e }) => e));
  for (const e of entries) {
    await tx.unsafe(
      `INSERT INTO task_ledger (tenant_id, member_id, task_key, signatures, task_kind, app_bundle_id, host, name_words, name, centroid, first_seen_day, last_seen_day)
       VALUES (${TID}, ${MID}, $1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
       ON CONFLICT (tenant_id, member_id, task_key) DO UPDATE SET signatures = EXCLUDED.signatures, task_kind = EXCLUDED.task_kind,
         app_bundle_id = EXCLUDED.app_bundle_id, host = EXCLUDED.host, name_words = EXCLUDED.name_words, name = EXCLUDED.name,
         centroid = EXCLUDED.centroid, first_seen_day = EXCLUDED.first_seen_day, last_seen_day = EXCLUDED.last_seen_day`,
      [e.taskKey, e.signatures, e.taskKind, e.appBundleId, e.host, e.nameWords, e.name, e.centroid, e.firstSeenDay, e.lastSeenDay],
    );
  }
}

// ---------- episodes and day records ----------

export async function saveEpisodes(tx: Tx, episodes: readonly Episode[]): Promise<void> {
  guard("episodes", episodes);
  for (const e of episodes) {
    await tx.unsafe(
      `INSERT INTO episodes (tenant_id, member_id, id, kind, day, started_at, ended_at, minutes, apps, task_key, name, evidence, source_purged_at, hosts)
       VALUES (${TID}, ${MID}, $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
       ON CONFLICT (tenant_id, member_id, id) DO UPDATE SET kind = EXCLUDED.kind, day = EXCLUDED.day, started_at = EXCLUDED.started_at,
         ended_at = EXCLUDED.ended_at, minutes = EXCLUDED.minutes, apps = EXCLUDED.apps, task_key = EXCLUDED.task_key, name = EXCLUDED.name,
         evidence = EXCLUDED.evidence, hosts = EXCLUDED.hosts`,
      [e.id, e.kind, e.day, e.started_at, e.ended_at, e.minutes, e.apps, e.task_key, e.name, e.evidence, e.source_purged_at, e.hosts ?? []],
    );
  }
}

const dayOfRow = (r: Row): DayRecord => ({
  day: r["day"], generated_at: iso(r["generated_at"])!, totals: r["totals"], by_kind: r["by_kind"], by_app: r["by_app"], by_task: r["by_task"],
  episode_ids: r["episode_ids"], source_purged_at: iso(r["source_purged_at"]),
});
const DAY_COLS = "day::text AS day, generated_at, totals, by_kind, by_app, by_task, episode_ids, source_purged_at";

export async function saveDayRecord(tx: Tx, r: DayRecord): Promise<void> {
  guard("day record", r);
  await tx.unsafe(
    `INSERT INTO day_records (tenant_id, member_id, day, generated_at, totals, by_kind, by_app, by_task, episode_ids, source_purged_at)
     VALUES (${TID}, ${MID}, $1, $2, $3::text::jsonb, $4::text::jsonb, $5::text::jsonb, $6::text::jsonb, $7, $8)
     ON CONFLICT (tenant_id, member_id, day) DO UPDATE SET generated_at = EXCLUDED.generated_at, totals = EXCLUDED.totals, by_kind = EXCLUDED.by_kind,
       by_app = EXCLUDED.by_app, by_task = EXCLUDED.by_task, episode_ids = EXCLUDED.episode_ids, source_purged_at = EXCLUDED.source_purged_at`,
    [r.day, r.generated_at, json(r.totals), json(r.by_kind), json(r.by_app), json(r.by_task), r.episode_ids, r.source_purged_at],
  );
  await indexFigures(tx, "day", r.day, r);
}

export async function getDayRecord(tx: Tx, day: string): Promise<DayRecord | null> {
  const [r] = await rows(tx, `SELECT ${DAY_COLS} FROM day_records WHERE ${OWN} AND day = $1::date`, [day]);
  return r === undefined ? null : dayOfRow(r);
}

export async function listDayRecords(tx: Tx, from: string, to: string): Promise<DayRecord[]> {
  return (await rows(tx, `SELECT ${DAY_COLS} FROM day_records WHERE ${OWN} AND day BETWEEN $1::date AND $2::date ORDER BY day`, [from, to])).map(dayOfRow);
}

export async function listAnalysedDays(tx: Tx): Promise<string[]> {
  return (await rows(tx, `SELECT day::text AS day FROM day_records WHERE ${OWN} ORDER BY day`)).map((r) => r["day"]);
}

// ---------- week, month and quarter records ----------

const weekOfRow = (r: Row): WeekRecord => ({
  iso_week: r["iso_week"], from: r["from_day"], to: r["to_day"], days_recorded: r["days_recorded"], hours: r["hours"], focus: r["focus"],
  tasks: r["tasks"], fixes: r["fixes"], weeks_observed: r["weeks_observed"], narrative: r["narrative"], generated_at: iso(r["generated_at"])!,
});
const WEEK_COLS = "iso_week, from_day::text AS from_day, to_day::text AS to_day, days_recorded::text[] AS days_recorded, hours, focus, tasks, fixes, weeks_observed, narrative, generated_at";

export async function saveWeekRecord(tx: Tx, r: WeekRecord): Promise<void> {
  guard("week record", r);
  await tx.unsafe(
    `INSERT INTO week_records (tenant_id, member_id, iso_week, from_day, to_day, days_recorded, hours, focus, tasks, fixes, weeks_observed, narrative, generated_at)
     VALUES (${TID}, ${MID}, $1, $2, $3, $4::date[], $5::text::jsonb, $6::text::jsonb, $7::text::jsonb, $8::text::jsonb, $9, $10, $11)
     ON CONFLICT (tenant_id, member_id, iso_week) DO UPDATE SET from_day = EXCLUDED.from_day, to_day = EXCLUDED.to_day, days_recorded = EXCLUDED.days_recorded,
       hours = EXCLUDED.hours, focus = EXCLUDED.focus, tasks = EXCLUDED.tasks, fixes = EXCLUDED.fixes, weeks_observed = EXCLUDED.weeks_observed,
       narrative = EXCLUDED.narrative, generated_at = EXCLUDED.generated_at`,
    [r.iso_week, r.from, r.to, r.days_recorded, json(r.hours), json(r.focus), json(r.tasks), json(r.fixes), r.weeks_observed, r.narrative, r.generated_at],
  );
  await indexFigures(tx, "week", r.iso_week, r);
}

export async function getWeekRecord(tx: Tx, isoWeek: string): Promise<WeekRecord | null> {
  const [r] = await rows(tx, `SELECT ${WEEK_COLS} FROM week_records WHERE ${OWN} AND iso_week = $1`, [isoWeek]);
  return r === undefined ? null : weekOfRow(r);
}

export async function listWeekRecords(tx: Tx, from: string, to: string): Promise<WeekRecord[]> {
  return (await rows(tx, `SELECT ${WEEK_COLS} FROM week_records WHERE ${OWN} AND iso_week BETWEEN $1 AND $2 ORDER BY iso_week`, [from, to])).map(weekOfRow);
}

export async function countWeeksBefore(tx: Tx, isoWeek: string): Promise<number> {
  return (await rows(tx, `SELECT count(*)::int AS n FROM week_records WHERE ${OWN} AND iso_week < $1`, [isoWeek]))[0]!["n"];
}

export async function setWeekNarrative(tx: Tx, isoWeek: string, narrative: string): Promise<void> {
  guard("narrative", narrative);
  if (hasAnyLink(narrative)) throw new LeakError("the weekly sentence would store a link; refused");
  await tx.unsafe(`UPDATE week_records SET narrative = $2 WHERE ${OWN} AND iso_week = $1`, [isoWeek, narrative]);
}

const ROLLUP_TABLE = { month: ["month_records", "month"], quarter: ["quarter_records", "quarter"] } as const;

export async function saveRollup(tx: Tx, r: RollupRecord): Promise<void> {
  guard("rollup", r);
  const [table, col] = ROLLUP_TABLE[r.kind];
  await tx.unsafe(
    `INSERT INTO ${table} (tenant_id, member_id, ${col}, weeks, hours, by_task, persistent, trend, drift, realized, outcomes, notes, narrative, generated_at)
     VALUES (${TID}, ${MID}, $1, $2, $3::text::jsonb, $4::text::jsonb, $5, $6::text::jsonb, $7::text::jsonb, NULL, '[]', $8, $9, $10)
     ON CONFLICT (tenant_id, member_id, ${col}) DO UPDATE SET weeks = EXCLUDED.weeks, hours = EXCLUDED.hours, by_task = EXCLUDED.by_task,
       persistent = EXCLUDED.persistent, trend = EXCLUDED.trend, drift = EXCLUDED.drift, notes = EXCLUDED.notes, narrative = EXCLUDED.narrative,
       generated_at = EXCLUDED.generated_at`,
    [r.period, r.weeks, json(r.hours), json(r.by_task), r.persistent, json(r.trend), json(r.drift), r.notes, r.narrative, r.generated_at],
  );
  await indexFigures(tx, r.kind, r.period, r);
}

export async function getRollup(tx: Tx, kind: "month" | "quarter", period: string): Promise<RollupRecord | null> {
  const [table, col] = ROLLUP_TABLE[kind];
  const [r] = await rows(tx, `SELECT * FROM ${table} WHERE ${OWN} AND ${col} = $1`, [period]);
  if (r === undefined) return null;
  return {
    kind, period: r[col], weeks: r["weeks"], hours: r["hours"], by_task: r["by_task"], persistent: r["persistent"], trend: r["trend"], drift: r["drift"],
    notes: r["notes"], narrative: r["narrative"], generated_at: iso(r["generated_at"])!,
  };
}

// ---------- propositions ----------

const ms = (v: unknown): number | null => (v === null || v === undefined ? null : v instanceof Date ? v.getTime() : new Date(String(v)).getTime());

export async function loadPropositions(tx: Tx): Promise<Proposition[]> {
  return (await rows(tx, `SELECT * FROM propositions WHERE ${OWN} ORDER BY key, version`)).map((r) => ({
    id: r["id"], key: r["key"], kind: r["kind"], version: r["version"], revisionGroup: r["revision_group"], text: r["text"],
    confidence: Number(r["confidence"]), confidenceScore: Number(r["confidence_score"]), decay: Number(r["decay"]), rate: Number(r["rate"]),
    evidence: r["evidence"], validAt: ms(r["valid_at"])!, invalidAt: ms(r["invalid_at"]), recordedAt: ms(r["recorded_at"])!, expiredAt: ms(r["expired_at"]),
  }));
}

/** Upserts by id; never deletes. Ended versions are written first so one current version per key always holds. */
export async function savePropositions(tx: Tx, props: readonly Proposition[]): Promise<void> {
  guard("propositions", props);
  const ordered = [...props].sort((a, b) => Number(a.invalidAt === null) - Number(b.invalidAt === null));
  const at = (v: number | null) => (v === null ? null : new Date(v).toISOString());
  for (const p of ordered) {
    await tx.unsafe(
      `INSERT INTO propositions (tenant_id, member_id, id, key, kind, version, revision_group, text, confidence, confidence_score, decay, rate, evidence, valid_at, invalid_at, recorded_at, expired_at)
       VALUES (${TID}, ${MID}, $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11::text::jsonb, $12, $13, $14, $15)
       ON CONFLICT (tenant_id, member_id, id) DO UPDATE SET text = EXCLUDED.text, confidence = EXCLUDED.confidence, confidence_score = EXCLUDED.confidence_score,
         decay = EXCLUDED.decay, rate = EXCLUDED.rate, evidence = EXCLUDED.evidence, valid_at = EXCLUDED.valid_at, invalid_at = EXCLUDED.invalid_at,
         expired_at = EXCLUDED.expired_at`,
      [p.id, p.key, p.kind, p.version, p.revisionGroup, p.text, p.confidence, p.confidenceScore, p.decay, p.rate, json(p.evidence), at(p.validAt), at(p.invalidAt), at(p.recordedAt), at(p.expiredAt)],
    );
  }
}

// ---------- review answers and opportunities ----------

const answerOf = (r: Row): ReviewAnswer => ({ iso_week: r["iso_week"], subject_key: r["subject_key"], question_kind: r["question_kind"], answer: r["answer"], goal_id: r["goal_id"], answered_at: iso(r["answered_at"])! });

export async function saveReviewAnswer(tx: Tx, a: ReviewAnswer): Promise<ReviewAnswer> {
  const [r] = await rows(
    tx,
    `INSERT INTO review_answers (tenant_id, member_id, iso_week, subject_key, question_kind, answer, goal_id, answered_at)
     VALUES (${TID}, ${MID}, $1, $2, $3, $4, $5, $6)
     ON CONFLICT (tenant_id, member_id, iso_week, subject_key) DO UPDATE SET question_kind = EXCLUDED.question_kind, answer = EXCLUDED.answer,
       goal_id = EXCLUDED.goal_id, answered_at = EXCLUDED.answered_at
     RETURNING iso_week, subject_key, question_kind, answer, goal_id, answered_at`,
    [a.iso_week, a.subject_key, a.question_kind, a.answer, a.goal_id, a.answered_at],
  );
  return answerOf(r!);
}

export async function listReviewAnswers(tx: Tx): Promise<ReviewAnswer[]> {
  return (await rows(tx, `SELECT iso_week, subject_key, question_kind, answer, goal_id, answered_at FROM review_answers WHERE ${OWN} ORDER BY iso_week, subject_key`)).map(answerOf);
}

/** The API `Opportunity` (docs/API.md) of a stored finder opportunity, with its options. */
export interface OpportunityView {
  id: string;
  source: "finder" | "manual" | "instant_read" | "agent";
  task_key: string | null;
  title: string;
  iso_week: string;
  rank: number | null;
  state: string;
  not_now_until: string | null;
  /** Masked description ('' for finder opportunities). */
  description: string;
  goal_id: string | null;
  /** The goal the opportunity advances, as the Mac decodes it (`OpportunityGoal`); null without one. */
  goal: { id: string; text: string } | null;
  score: Figure | null;
  factors: Partial<RankedOpportunity["factors"]>;
  /** No option saves 0.5 h a week: no option is recommended and "leave it alone" should come first. */
  leave_alone_first: boolean;
  /** Each option with its row id and `estimate`, the hours-per-week Figure the Mac shows ("saves N h/wk"); it equals
   * `figures.weekly_hours_saved`. */
  options: Array<FixOption & { id: string; estimate: Figure; chosen_at: string | null }>;
}

/** Episodes of the days from..to, read through day_records.episode_ids (never by episodes.day alone: a re-analysed
 * day can leave older episode rows behind). */
export async function listWeekEpisodes(tx: Tx, from: string, to: string): Promise<Episode[]> {
  const rs = await rows(
    tx,
    `SELECT e.id, e.kind, e.day::text AS day, e.started_at, e.ended_at, e.minutes::float8 AS minutes, e.apps, e.hosts, e.task_key, e.name, e.evidence, e.source_purged_at
       FROM day_records d JOIN episodes e ON e.tenant_id = d.tenant_id AND e.member_id = d.member_id AND e.id = ANY(d.episode_ids)
      WHERE d.tenant_id = ${TID} AND d.member_id = ${MID} AND d.day BETWEEN $1::date AND $2::date
      ORDER BY e.started_at, e.id`,
    [from, to],
  );
  return rs.map((r) => ({
    id: r["id"], kind: r["kind"], day: r["day"], started_at: iso(r["started_at"])!, ended_at: iso(r["ended_at"])!, minutes: Number(r["minutes"]), apps: r["apps"],
    hosts: r["hosts"], task_key: r["task_key"], name: r["name"], evidence: r["evidence"], source_purged_at: iso(r["source_purged_at"]),
  }));
}

type StoredOption = OpportunityView["options"][number];
const optionOf = (r: Row): StoredOption => ({
  id: r["id"], option_no: Number(r["option_no"]), kind: r["kind"], rule: r["rule"], recommended: r["recommended"], title: r["title"], detail: r["detail"],
  steps: r["steps"], figures: r["figures"], estimate: r["estimate"], chosen_at: iso(r["chosen_at"]),
});

async function optionsOf(tx: Tx, opportunityIds: readonly string[]): Promise<Map<string, StoredOption[]>> {
  const out = new Map<string, StoredOption[]>();
  if (opportunityIds.length === 0) return out;
  for (const r of await rows(tx, `SELECT * FROM fixes WHERE ${OWN} AND opportunity_id = ANY($1::uuid[]) ORDER BY opportunity_id, option_no`, [opportunityIds])) {
    const id = String(r["opportunity_id"]);
    out.set(id, [...(out.get(id) ?? []), optionOf(r)]);
  }
  return out;
}

function viewOf(r: Row, options: StoredOption[]): OpportunityView {
  const { score, ...factors } = (r["factors"] ?? {}) as Partial<RankedOpportunity["factors"]> & { score?: Figure };
  return {
    id: r["id"], source: r["source"], task_key: r["task_key"], title: r["title"], iso_week: r["iso_week"], rank: r["rank"], state: r["state"],
    not_now_until: r["not_now_until"] ?? null, description: r["description"] ?? "", goal_id: r["goal_id"], goal: r["goal"] ?? null,
    score: score ?? null, factors,
    leave_alone_first: options.length > 0 && Math.max(...options.map((o) => o.figures.weekly_hours_saved.value)) < LEAVE_ALONE_BELOW_HOURS,
    options,
  };
}

const OPP_COLS = `id, source, task_key, title, description, iso_week, rank, state, not_now_until::text AS not_now_until, goal_id, factors,
  (SELECT jsonb_build_object('id', g.id, 'text', g.text) FROM goals g
    WHERE g.tenant_id = opportunities.tenant_id AND g.member_id = opportunities.member_id AND g.id = opportunities.goal_id) AS goal`;

/** The member's opportunities of `isoWeek` (default: the latest week that has any), optionally in one state, with their
 * options. Ordered by rank, unranked last. */
export async function listOpportunityViews(tx: Tx, opts: { isoWeek?: string; state?: string } = {}): Promise<OpportunityView[]> {
  const week = opts.isoWeek ?? (await rows(tx, `SELECT max(iso_week) AS w FROM opportunities WHERE ${OWN}`))[0]?.["w"];
  if (week === null || week === undefined) return [];
  const rs = await rows(
    tx,
    `SELECT ${OPP_COLS} FROM opportunities WHERE ${OWN} AND iso_week = $1 AND ($2::text IS NULL OR state = $2) ORDER BY rank NULLS LAST, task_key, id`,
    [week, opts.state ?? null],
  );
  const options = await optionsOf(tx, rs.map((r) => String(r["id"])));
  return rs.map((r) => viewOf(r, options.get(String(r["id"])) ?? []));
}

export async function getOpportunityView(tx: Tx, id: string): Promise<OpportunityView | null> {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) return null;
  const [r] = await rows(tx, `SELECT ${OPP_COLS} FROM opportunities WHERE ${OWN} AND id = $1`, [id]);
  if (r === undefined) return null;
  return viewOf(r, (await optionsOf(tx, [id])).get(id) ?? []);
}

/** Upserts an open opportunity's options by option number (ids and created_at are kept) and drops numbers past them.
 * Options of an opportunity that is no longer open, or has a chosen option, are left as they are. */
async function saveOptions(tx: Tx, opp: { id: string; state: string }, workspaceId: string, options: readonly FixOption[], now: number): Promise<void> {
  if (opp.state !== "open") return;
  const [chosen] = await rows(tx, `SELECT 1 FROM fixes WHERE ${OWN} AND opportunity_id = $1 AND chosen_at IS NOT NULL LIMIT 1`, [opp.id]);
  if (chosen !== undefined) return;
  // Only option 1 is ever recommended, so upserting by option number keeps the one-recommended index true.
  await tx.unsafe(`DELETE FROM fixes WHERE ${OWN} AND opportunity_id = $1 AND option_no > $2`, [opp.id, options.length]);
  for (const o of options) {
    await tx.unsafe(
      `INSERT INTO fixes (tenant_id, id, member_id, workspace_id, opportunity_id, option_no, kind, rule, recommended, title, detail, estimate, confidence, effort_hours, figures, steps, created_at)
       VALUES (${TID}, $1, ${MID}, $2, $3, $4, $5, $6, $7, $8, $9, $10::text::jsonb, $11, $12, $13::text::jsonb, $14::text::jsonb, $15)
       ON CONFLICT (tenant_id, opportunity_id, option_no) DO UPDATE SET workspace_id = EXCLUDED.workspace_id, kind = EXCLUDED.kind, rule = EXCLUDED.rule,
         recommended = EXCLUDED.recommended, title = EXCLUDED.title, detail = EXCLUDED.detail, estimate = EXCLUDED.estimate, confidence = EXCLUDED.confidence,
         effort_hours = EXCLUDED.effort_hours, figures = EXCLUDED.figures, steps = EXCLUDED.steps`,
      [
        uuidv7(now), workspaceId, opp.id, o.option_no, o.kind, o.rule, o.recommended, o.title, o.detail, json(o.figures.weekly_hours_saved), o.figures.confidence.value,
        o.figures.setup_hours.value, json(o.figures), json(o.steps), new Date(now).toISOString(),
      ],
    );
  }
}

/** Stores the week's top 5 finder opportunities and, for each, its proposed options (by task key). An open finder
 * opportunity that left the top 5 is deleted with its options. */
export async function saveOpportunities(tx: Tx, input: { isoWeek: string; workspaceId: string; ranked: readonly RankedOpportunity[]; now: number; options?: ReadonlyMap<string, readonly FixOption[]> }): Promise<void> {
  guard("opportunities", input.ranked);
  if (input.options !== undefined) guard("fix options", [...input.options.values()]);
  const keys = input.ranked.map((o) => o.task_key);
  // Their options go with them through fixes' ON DELETE CASCADE (0002_fixes.sql). One whose option was picked stays
  // (unranked), like its options in saveOptions (review 2 finding 3).
  const gone = await rows(
    tx,
    `DELETE FROM opportunities o WHERE o.tenant_id = ${TID} AND o.member_id = ${MID} AND o.iso_week = $1 AND o.source = 'finder' AND o.state = 'open'
       AND NOT (o.task_key = ANY($2::text[]))
       AND NOT EXISTS (SELECT 1 FROM fixes f WHERE f.tenant_id = o.tenant_id AND f.opportunity_id = o.id AND f.chosen_at IS NOT NULL)
     RETURNING o.task_key`,
    [input.isoWeek, keys],
  );
  for (const g of gone) await tx.unsafe(`DELETE FROM figure_index WHERE ${OWN} AND record_kind = 'opportunity' AND record_key = $1`, [`${input.isoWeek}/${g["task_key"]}`]);
  await tx.unsafe(`UPDATE opportunities SET rank = NULL WHERE ${OWN} AND iso_week = $1 AND source = 'finder' AND NOT (task_key = ANY($2::text[]))`, [input.isoWeek, keys]);
  for (const o of input.ranked) {
    const factors = { ...o.factors, score: o.score };
    const [saved] = await rows(
      tx,
      `INSERT INTO opportunities (tenant_id, id, member_id, workspace_id, source, task_key, title, description, iso_week, rank, score, factors, state, goal_id, created_at)
       VALUES (${TID}, $1, ${MID}, $2, 'finder', $3, $4, '', $5, $6, $7, $8::text::jsonb, 'open', $9, $10)
       ON CONFLICT (tenant_id, member_id, iso_week, task_key) WHERE source = 'finder'
       DO UPDATE SET title = EXCLUDED.title, rank = EXCLUDED.rank, score = EXCLUDED.score, factors = EXCLUDED.factors, goal_id = EXCLUDED.goal_id
       RETURNING id, state`,
      [uuidv7(input.now), input.workspaceId, o.task_key, o.name, input.isoWeek, o.rank, o.score.value, json(factors), o.goal_id, new Date(input.now).toISOString()],
    );
    const opp = { id: String(saved!["id"]), state: String(saved!["state"]) };
    const options = input.options?.get(o.task_key);
    if (options !== undefined) await saveOptions(tx, opp, input.workspaceId, options, input.now);
    // The record "how it was counted" resolves: the factors and every stored option's figures.
    const stored = (await optionsOf(tx, [opp.id])).get(opp.id) ?? [];
    await indexFigures(tx, "opportunity", `${input.isoWeek}/${o.task_key}`, { factors, options: stored.map((x) => x.figures) });
  }
}

export async function listOpportunities(tx: Tx, isoWeek: string): Promise<StoredOpportunity[]> {
  return (await rows(tx, `SELECT id, task_key, title, rank, score::float8 AS score, state, goal_id, factors FROM opportunities WHERE ${OWN} AND iso_week = $1 ORDER BY rank NULLS LAST, task_key`, [isoWeek])).map((r) => {
    const { score: _s, ...factors } = r["factors"] as RankedOpportunity["factors"] & { score: unknown };
    return { id: r["id"], task_key: r["task_key"], name: r["title"], rank: r["rank"], state: r["state"], score: r["score"] ?? 0, goal_id: r["goal_id"], factors };
  });
}

const STATE_OF: Partial<Record<Answer, string>> = { not_now: "not_now", never: "never", leave_alone: "left_alone", keep: "open", other_goal: "open" };

/** Applies a review answer to the week's finder opportunity for that task (declines; a later keep reopens). */
export async function applyAnswerToOpportunity(tx: Tx, a: ReviewAnswer): Promise<void> {
  const state = STATE_OF[a.answer];
  if (state === undefined) return;
  const until = a.answer === "not_now" ? weekDays(addWeeks(a.iso_week, 4))[0]! : null;
  await tx.unsafe(
    `UPDATE opportunities SET state = $1, not_now_until = $2 WHERE ${OWN} AND iso_week = $3 AND task_key = $4 AND source = 'finder' AND state IN ('open', 'not_now', 'never', 'left_alone')`,
    [state, until, a.iso_week, a.subject_key],
  );
}

/** The retention job marks a day whose raw evidence passed its TTL: values kept, figures re-indexed. */
export async function markSourcePurged(tx: Tx, day: string, at: string): Promise<void> {
  const rec = await getDayRecord(tx, day);
  if (rec === null) return;
  await saveDayRecord(tx, { ...withSourcePurged(rec, at), source_purged_at: at });
  await tx.unsafe(`UPDATE episodes SET source_purged_at = $2 WHERE ${OWN} AND day = $1::date AND source_purged_at IS NULL`, [day, at]);
}

export async function resolveFigure(tx: Tx, figureId: string): Promise<{ record_kind: string; record_key: string; json_pointer: string } | null> {
  const [r] = await rows(tx, `SELECT record_kind, record_key, json_pointer FROM figure_index WHERE ${OWN} AND figure_id = $1 ORDER BY created_at, record_kind, record_key, json_pointer LIMIT 1`, [figureId]);
  return r === undefined ? null : { record_kind: r["record_kind"], record_key: r["record_key"], json_pointer: r["json_pointer"] };
}
