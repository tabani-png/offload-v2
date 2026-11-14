// Day records and episodes (old brain/src/memory/day-record.ts): one record per closed member-timezone day, code only.
// Derived only: minutes, counts, bundle ids, masked task names and observation ids as evidence. Window titles are
// never read here.
import { createHash } from "node:crypto";
import { taskName } from "../user-model/names.ts";
import { median } from "../user-model/observe.ts";
import type { DayLabel, UnderstandingWindow, WindowSpan } from "../user-model/ports.ts";
import { dayOf } from "./dates.ts";
import { figure, r1, type EvidenceRef, type Figure } from "./figure.ts";
import { kindOf, type WorkKind } from "./kinds.ts";

export const FOCUS_BLOCK_MINUTES = 25;
export const FOCUS_GAP_SECONDS = 120;

export interface Episode {
  /** `ep_` + instance id, or `ep_fb_` + 12 hex for a focus block. */
  id: string;
  kind: "focus_block" | "task_instance";
  day: DayLabel;
  started_at: string;
  ended_at: string;
  minutes: number;
  apps: string[];
  task_key: string | null;
  /** Masked verb-object name. */
  name: string;
  /** Observation ids. */
  evidence: string[];
  source_purged_at: string | null;
}

export interface DayRecord {
  day: DayLabel;
  generated_at: string;
  totals: {
    active_minutes: Figure;
    switches: Figure;
    switches_per_active_hour: Figure;
    focus_blocks: Figure;
    focus_minutes: Figure;
    meeting_minutes: Figure;
  };
  by_kind: Array<{ kind: WorkKind; minutes: Figure }>;
  by_app: Array<{ app: string; minutes: Figure }>;
  by_task: Array<{ task_key: string; name: string; minutes: Figure; instances: Figure; median_minutes: Figure }>;
  episode_ids: string[];
  source_purged_at: string | null;
}

const iso = (ms: number) => new Date(ms).toISOString();
const obsRefs = (spans: readonly WindowSpan[]): EvidenceRef[] => [...new Set(spans.flatMap((s) => s.observationIds))].map((id) => ({ kind: "observation", id }));
const epRefs = (ids: readonly string[]): EvidenceRef[] => ids.map((id) => ({ kind: "episode", id }));
const byMinutes = <T extends { minutes: Figure }>(key: (x: T) => string) => (a: T, b: T) => b.minutes.value - a.minutes.value || (key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0);

/** Records for every closed day of the window (days before today in the member's timezone at `now`). */
export function buildDayRecords(
  window: UnderstandingWindow,
  keys: ReadonlyMap<string, string>,
  now: number,
): { records: DayRecord[]; episodes: Episode[] } {
  const tz = window.timezone;
  const today = dayOf(now, tz);
  const closed = [...new Set(window.days)].filter((d) => d < today).sort();
  const spansById = new Map(window.spans.map((s) => [s.id, s]));
  const taskOfSpan = new Map<string, string>();
  const nameOfKey = new Map<string, string>();
  for (const t of window.tasks) {
    const key = keys.get(t.id);
    if (key === undefined) continue;
    nameOfKey.set(key, taskName(t.name, t.kind));
    for (const i of t.instances) for (const sid of i.spanIds) taskOfSpan.set(sid, key);
  }
  const records: DayRecord[] = [];
  const episodes: Episode[] = [];
  for (const day of closed) {
    const spans = window.spans.filter((s) => dayOf(s.start, tz) === day).sort((a, b) => a.start - b.start || (a.id < b.id ? -1 : 1));
    const dayEpisodes: Episode[] = [];

    // Task instances.
    const perTask = new Map<string, { seconds: number[]; episodeIds: string[] }>();
    for (const t of window.tasks) {
      const key = keys.get(t.id);
      if (key === undefined) continue;
      for (const i of t.instances) {
        if (dayOf(i.start, tz) !== day) continue;
        const apps = [...new Set(i.spanIds.map((id) => spansById.get(id)?.appBundleId).filter((x): x is string => x !== undefined))].sort();
        const e: Episode = {
          id: `ep_${i.id}`, kind: "task_instance", day, started_at: iso(i.start), ended_at: iso(i.end), minutes: r1(i.activeSeconds / 60),
          apps, task_key: key, name: nameOfKey.get(key)!, evidence: [...i.observationIds], source_purged_at: null,
        };
        dayEpisodes.push(e);
        const x = perTask.get(key) ?? { seconds: [], episodeIds: [] };
        x.seconds.push(i.activeSeconds);
        x.episodeIds.push(e.id);
        perTask.set(key, x);
      }
    }

    // Focus blocks: runs of spans of one task with gaps under FOCUS_GAP_SECONDS, at least FOCUS_BLOCK_MINUTES active
    // (ARCHITECTURE section 5: gaps under 2 min).
    let run: { key: string; spans: WindowSpan[]; end: number; seconds: number } | undefined;
    const runs: Array<NonNullable<typeof run>> = [];
    for (const s of spans) {
      const key = taskOfSpan.get(s.id);
      if (run !== undefined && key !== undefined && run.key === key && s.start - run.end < FOCUS_GAP_SECONDS * 1000) {
        run.spans.push(s);
        run.end = Math.max(run.end, s.end);
        run.seconds += s.activeSeconds;
        continue;
      }
      if (run !== undefined) runs.push(run);
      run = key === undefined ? undefined : { key, spans: [s], end: s.end, seconds: s.activeSeconds };
    }
    if (run !== undefined) runs.push(run);
    const blocks = runs.filter((b) => b.seconds >= FOCUS_BLOCK_MINUTES * 60);
    for (const b of blocks) {
      const start = b.spans[0]!.start;
      dayEpisodes.push({
        id: `ep_fb_${createHash("sha256").update(`${b.key}|${start}`).digest("hex").slice(0, 12)}`, kind: "focus_block", day,
        started_at: iso(start), ended_at: iso(b.end), minutes: r1(b.seconds / 60), apps: [...new Set(b.spans.map((s) => s.appBundleId))].sort(),
        task_key: b.key, name: nameOfKey.get(b.key)!, evidence: [...new Set(b.spans.flatMap((s) => s.observationIds))], source_purged_at: null,
      });
    }

    // Totals.
    const activeSeconds = spans.reduce((n, s) => n + s.activeSeconds, 0);
    const activeMinutes = r1(activeSeconds / 60);
    let switches = 0;
    const switchRefs: EvidenceRef[] = [];
    for (let i = 1; i < spans.length; i++) {
      if (spans[i]!.appBundleId === spans[i - 1]!.appBundleId) continue;
      switches += 1;
      const first = spans[i]!.observationIds[0];
      if (first !== undefined) switchRefs.push({ kind: "observation", id: first });
    }
    const perHour = activeMinutes === 0 ? 0 : r1(switches / (activeMinutes / 60));
    const kindSpans = new Map<WorkKind, WindowSpan[]>();
    const appSpans = new Map<string, WindowSpan[]>();
    for (const s of spans) {
      const k = kindOf(s);
      kindSpans.set(k, [...(kindSpans.get(k) ?? []), s]);
      appSpans.set(s.appBundleId, [...(appSpans.get(s.appBundleId) ?? []), s]);
    }
    const minutesOf = (xs: readonly WindowSpan[]) => r1(xs.reduce((n, s) => n + s.activeSeconds, 0) / 60);
    const meeting = kindSpans.get("meeting") ?? [];
    const blockIds = dayEpisodes.filter((e) => e.kind === "focus_block").map((e) => e.id).sort();
    const focusMinutes = r1(blocks.reduce((n, b) => n + b.seconds, 0) / 60);
    dayEpisodes.sort((a, b) => (a.started_at < b.started_at ? -1 : a.started_at > b.started_at ? 1 : a.id < b.id ? -1 : 1));
    episodes.push(...dayEpisodes);

    records.push({
      day,
      generated_at: iso(now),
      totals: {
        active_minutes: figure(activeMinutes, "minutes", `sum of ${spans.length} spans' active time, idle removed = ${activeMinutes} min`, obsRefs(spans)),
        switches: figure(switches, "count", `${switches} times the app changed between consecutive spans`, switchRefs),
        switches_per_active_hour: figure(perHour, "per_hour", `${switches} switches / (${activeMinutes} min / 60) = ${perHour} per active hour`, []),
        focus_blocks: figure(blocks.length, "count", `runs of one task with gaps under ${FOCUS_GAP_SECONDS / 60} min lasting at least ${FOCUS_BLOCK_MINUTES} min: ${blocks.length}`, epRefs(blockIds)),
        focus_minutes: figure(focusMinutes, "minutes", `active time in ${blocks.length} focus blocks = ${focusMinutes} min`, epRefs(blockIds)),
        meeting_minutes: figure(minutesOf(meeting), "minutes", `active time of ${meeting.length} meeting spans = ${minutesOf(meeting)} min`, obsRefs(meeting)),
      },
      by_kind: [...kindSpans].map(([kind, xs]) => ({ kind, minutes: figure(minutesOf(xs), "minutes", `active time of ${xs.length} ${kind} spans = ${minutesOf(xs)} min`, obsRefs(xs)) })).sort(byMinutes((x) => x.kind)),
      by_app: [...appSpans].map(([app, xs]) => ({ app, minutes: figure(minutesOf(xs), "minutes", `active time of ${xs.length} spans in ${app} = ${minutesOf(xs)} min`, obsRefs(xs)) })).sort(byMinutes((x) => x.app)),
      by_task: [...perTask].map(([task_key, x]) => {
        const minutes = r1(x.seconds.reduce((a, b) => a + b, 0) / 60);
        const med = r1(median(x.seconds.map((s) => s / 60)));
        return {
          task_key, name: nameOfKey.get(task_key)!,
          minutes: figure(minutes, "minutes", `active time of ${x.seconds.length} instances = ${minutes} min`, epRefs(x.episodeIds)),
          instances: figure(x.seconds.length, "count", `${x.seconds.length} instances on ${day}`, epRefs(x.episodeIds)),
          median_minutes: figure(med, "minutes", `median of ${x.seconds.length} instances' active minutes = ${med} min`, epRefs(x.episodeIds)),
        };
      }).sort(byMinutes((x) => x.task_key)),
      episode_ids: dayEpisodes.map((e) => e.id).sort(),
      source_purged_at: null,
    });
  }
  return { records, episodes };
}
