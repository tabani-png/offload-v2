// The member update job: runs the p43a pipeline for one analysed window inside one tenant transaction and saves it.
// Called by the durable runtime (W1-C, m5-05) per member; running it twice with the same window leaves the same rows.
// No network I/O: the weekly sentence is written by writeWeekNarrative, outside the data transaction.
import { rankOpportunities, PERSISTENCE_WEEKS, type FixEstimate } from "../opportunities/score.ts";
import { userContextOf } from "../profile/profile.ts";
import { addWeeks, isoWeekOf, monthOfWeek, quarterOfWeek, weekDays } from "../records/dates.ts";
import { checkNarrative, writeWeekSentence } from "../records/narrative.ts";
import { buildRollup } from "../records/rollup.ts";
import { BASELINE_WEEKS, buildWeekRecord, type WeekTask } from "../records/week-record.ts";
import type { CompleteText, UnderstandingWindow } from "../user-model/ports.ts";
import { hasLink } from "../user-model/names.ts";
import { updateMemberModel } from "../user-model/update.ts";
import * as repo from "./repository.ts";
import type { RunInTenant, TenantContext, Tx } from "./tenant.ts";

/** The window was built in another timezone than the member's profile (DATA_MODEL section 1: days are profile days). */
export class TimezoneMismatchError extends Error {
  readonly code = "timezone_mismatch";
  /** Retrying the same window can never succeed: the caller rebuilds it in the profile's timezone. */
  readonly retryable = false;
}

export interface MemberUpdateInput {
  window: UnderstandingWindow;
  now: number;
  workspaceId: string;
  /** Fix rules for a week's task (m5-04 port); null = no fix proposed. */
  estimateFor?: (task: WeekTask) => Omit<FixEstimate, "taskKey"> | null;
  taskVectors?: ReadonlyMap<string, readonly number[]>;
  trackRecord?: ReadonlyMap<string, number>;
}

export interface MemberUpdateResult {
  days: string[];
  weeks: string[];
  months: string[];
  quarters: string[];
  ranked: number;
}

export async function runMemberUpdate(tx: Tx, input: MemberUpdateInput): Promise<MemberUpdateResult> {
  const { now } = input;
  const profile = await repo.getProfile(tx);
  if (input.window.timezone !== profile.timezone) {
    throw new TimezoneMismatchError(`the window's timezone ${input.window.timezone} is not the profile's timezone ${profile.timezone}`);
  }
  const state = { ledger: await repo.loadLedger(tx), propositions: await repo.loadPropositions(tx), analysedDays: await repo.listAnalysedDays(tx) };
  const u = updateMemberModel(input.window, state, now);
  await repo.saveLedger(tx, u.ledger);
  await repo.saveEpisodes(tx, u.episodes);
  for (const d of u.dayRecords) await repo.saveDayRecord(tx, d);
  await repo.savePropositions(tx, u.propositions);

  const weeks = [...new Set(u.dayRecords.map((d) => isoWeekOf(d.day)))].sort();
  for (const w of weeks) {
    const days = weekDays(w);
    const existing = await repo.getWeekRecord(tx, w);
    const rec = buildWeekRecord({
      isoWeek: w, days: await repo.listDayRecords(tx, days[0]!, days[6]!), prior: await repo.listWeekRecords(tx, addWeeks(w, -BASELINE_WEEKS), addWeeks(w, -1)),
      weeksObserved: (await repo.countWeeksBefore(tx, w)) + 1, now,
    });
    // A stored sentence survives a rebuild only while every number in it is still in the record.
    if (existing?.narrative != null && checkNarrative(existing.narrative, rec).ok) rec.narrative = existing.narrative;
    await repo.saveWeekRecord(tx, rec);
  }
  const months = [...new Set(weeks.map(monthOfWeek))].sort();
  const quarters = [...new Set(weeks.map(quarterOfWeek))].sort();
  if (weeks.length > 0) {
    const all = await repo.listWeekRecords(tx, "0000-W01", "9999-W53");
    for (const [kind, periods] of [["month", months], ["quarter", quarters]] as const) {
      for (const p of periods) {
        const r = buildRollup(kind, p, all, profile.drains, now);
        if (r !== null) await repo.saveRollup(tx, r);
      }
    }
  }

  let ranked = 0;
  const latest = weeks[weeks.length - 1];
  if (input.estimateFor !== undefined && latest !== undefined) {
    const week = (await repo.getWeekRecord(tx, latest))!;
    const estimates: FixEstimate[] = [];
    for (const t of week.tasks) {
      const e = input.estimateFor(t);
      if (e !== null) estimates.push({ ...e, taskKey: t.task_key });
    }
    const goals = (await repo.listGoals(tx)).map((g) => ({ id: g.id, embedding: g.embedding }));
    const r = rankOpportunities({
      isoWeek: latest, week, recent: await repo.listWeekRecords(tx, addWeeks(latest, -(PERSISTENCE_WEEKS - 1)), latest), estimates,
      drains: profile.drains, goals, taskVectors: input.taskVectors ?? new Map(), answers: await repo.listReviewAnswers(tx),
      ...(input.trackRecord === undefined ? {} : { trackRecord: input.trackRecord }),
    });
    await repo.saveOpportunities(tx, { isoWeek: latest, workspaceId: input.workspaceId, ranked: r, now });
    ranked = r.length;
  }
  return { days: u.dayRecords.map((d) => d.day), weeks, months, quarters, ranked };
}

/** Reads the week (transaction 1), asks the model outside any transaction, stores a checked sentence (transaction 2). */
export async function writeWeekNarrative(run: RunInTenant, ctx: TenantContext, isoWeek: string, complete: CompleteText | null): Promise<"model" | "code" | "none"> {
  const read = await run(ctx, async (tx) => ({ week: await repo.getWeekRecord(tx, isoWeek), profile: await repo.getProfile(tx) }));
  if (read.week === null) return "none";
  const { sentence, source } = await writeWeekSentence(read.week, userContextOf(read.profile), complete);
  if (source === "code") return "code";
  return run(ctx, async (tx) => {
    const week = await repo.getWeekRecord(tx, isoWeek);
    if (week === null || hasLink(sentence) || !checkNarrative(sentence, week).ok) return "code" as const;
    await repo.setWeekNarrative(tx, isoWeek, sentence);
    return "model" as const;
  });
}
