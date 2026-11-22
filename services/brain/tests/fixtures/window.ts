// Synthetic understanding windows for the user-model tests. Deterministic for a seed. Every name, address and URL is
// made up. Titles, task names, text snapshots and URLs deliberately carry leaky strings (emails, digits, URLs), so the
// privacy tests can check that none of them reaches the user model.
import type { DayLabel, UnderstandingWindow, WindowInstance, WindowSpan, WindowTask } from "../../src/user-model/ports.ts";

export const SEED = 42;
/** Week 1 (ISO 2026-W42) starts Monday 12 Oct 2026; four weeks run to Sunday 8 Nov 2026. */
export const MONDAYS = ["2026-10-12", "2026-10-19", "2026-10-26", "2026-11-02"] as const;
export const WEEKS = ["2026-W42", "2026-W43", "2026-W44", "2026-W45"] as const;

export interface TaskSpec {
  ref: string;
  kind: string;
  name: string;
  appBundleId: string;
  appName: string;
  host: string;
  /** Instances per weekday [min, max]; weekends get none unless `weekend`. */
  perDay: [number, number];
  minutes: [number, number];
  sameness: number;
  weekend?: boolean;
  /** Basis vector index for the centroid. */
  axis: number;
}

export const TASKS: readonly TaskSpec[] = [
  { ref: "outreach", kind: "email.outreach", name: "Outreach emails", appBundleId: "com.google.Chrome", appName: "Google Chrome", host: "mail.google.com", perDay: [10, 14], minutes: [3, 6], sameness: 0.9, axis: 0 },
  { ref: "report", kind: "sheet.update-report", name: "Update the weekly report", appBundleId: "com.microsoft.Excel", appName: "Microsoft Excel", host: "", perDay: [1, 1], minutes: [30, 40], sameness: 0.8, axis: 1 },
  { ref: "calls", kind: "call.meetings", name: "Calls in zoom", appBundleId: "us.zoom.xos", appName: "zoom.us", host: "", perDay: [1, 2], minutes: [20, 30], sameness: 0.6, axis: 2 },
  { ref: "review", kind: "code.review", name: "Review pull requests", appBundleId: "com.microsoft.VSCode", appName: "Code", host: "", perDay: [2, 3], minutes: [10, 15], sameness: 0.7, axis: 3 },
  { ref: "invoice", kind: "email.invoice", name: "Reply to dana@fund.example about invoice 4411 https://billing.example.com/inv/4411", appBundleId: "com.apple.mail", appName: "Mail", host: "", perDay: [1, 2], minutes: [4, 8], sameness: 0.5, axis: 4 },
  { ref: "slack", kind: "chat.reply", name: "Slack replies", appBundleId: "com.tinyspeck.slackmacgap", appName: "Slack", host: "", perDay: [4, 6], minutes: [1, 3], sameness: 0.7, weekend: true, axis: 5 },
];

export const DIM = 8;

export interface RawStrings {
  titles: string[];
  texts: string[];
  urls: string[];
  emails: string[];
  observationIds: string[];
}

export interface FixtureWeek {
  window: UnderstandingWindow;
  raw: RawStrings;
  /** window task id -> spec ref */
  refOf: Map<string, string>;
}

function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function addDay(day: DayLabel, n: number): DayLabel {
  const [y, m, d] = day.split("-").map(Number) as [number, number, number];
  return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10);
}

const utc = (day: DayLabel, hh: number, mm = 0) => {
  const [y, m, d] = day.split("-").map(Number) as [number, number, number];
  return Date.UTC(y, m - 1, d, hh, mm);
};

/** Noon UTC on the Monday after the week that starts on `monday`: every day of that week is closed. */
export const mondayNoonAfter = (monday: DayLabel) => utc(addDay(monday, 7), 12);

export function centroidOf(spec: TaskSpec, rand: () => number): number[] {
  const v = Array.from({ length: DIM }, () => (rand() - 0.5) * 0.05);
  v[spec.axis] = 1;
  v[(spec.axis + 1) % DIM] = (v[(spec.axis + 1) % DIM] ?? 0) + 0.2;
  return v.map((x) => Math.round(x * 1e4) / 1e4);
}

export interface WeekOptions {
  seed?: number;
  /** Task refs to leave out (the work stopped). */
  without?: readonly string[];
  timezone?: string;
  /** Override a spec's fields (for example a different signature or name). */
  override?: Record<string, Partial<TaskSpec> & { signature?: string }>;
}

/** One fixture week of work starting on `monday` (7 days). Work runs from 09:00 UTC. */
export function fixtureWeek(monday: DayLabel, opts: WeekOptions = {}): FixtureWeek {
  const rand = mulberry32(opts.seed ?? SEED);
  const pick = (lo: number, hi: number) => lo + Math.floor(rand() * (hi - lo + 1));
  const days = Array.from({ length: 7 }, (_, i) => addDay(monday, i));
  const raw: RawStrings = { titles: [], texts: [], urls: [], emails: [], observationIds: [] };
  const spans: WindowSpan[] = [];
  const tasks = new Map<string, WindowTask>();
  const refOf = new Map<string, string>();
  const specs = TASKS.filter((t) => !(opts.without ?? []).includes(t.ref)).map((t) => ({ ...t, ...(opts.override?.[t.ref] ?? {}) }));
  for (const spec of specs) {
    const id = `t_${monday.replaceAll("-", "")}_${spec.ref}`;
    const signature = opts.override?.[spec.ref]?.signature ?? `${spec.appBundleId}|${spec.host}|${spec.kind}`;
    tasks.set(spec.ref, {
      id, signature, kind: spec.kind, name: spec.name, appBundleId: spec.appBundleId, appName: spec.appName, host: spec.host,
      centroid: centroidOf(spec, rand), sameness: spec.sameness, instances: [],
    });
    refOf.set(id, spec.ref);
  }
  let spanNo = 0;
  days.forEach((day, di) => {
    const weekend = di >= 5;
    const queue: string[] = [];
    for (const spec of specs) {
      if (weekend && spec.weekend !== true) continue;
      const n = weekend ? 1 : pick(spec.perDay[0], spec.perDay[1]);
      for (let i = 0; i < n; i++) queue.push(spec.ref);
    }
    for (let i = queue.length - 1; i > 0; i--) {
      const j = Math.floor(rand() * (i + 1));
      [queue[i], queue[j]] = [queue[j]!, queue[i]!];
    }
    let t = utc(day, 9);
    queue.forEach((ref, qi) => {
      const spec = specs.find((s) => s.ref === ref)!;
      const task = tasks.get(ref)!;
      const minutes = pick(spec.minutes[0], spec.minutes[1]);
      const parts = minutes >= 20 ? 3 : minutes >= 6 ? 2 : 1;
      const inst: WindowInstance = { id: `i_${day.replaceAll("-", "")}_${qi}`, start: t, end: t, activeSeconds: 0, spanIds: [], observationIds: [] };
      for (let p = 0; p < parts; p++) {
        const secs = Math.round((minutes * 60) / parts);
        spanNo += 1;
        const sid = `sp_${day.replaceAll("-", "")}_${spanNo}`;
        const obs = [`obs_${day.replaceAll("-", "")}_${spanNo}_a`, `obs_${day.replaceAll("-", "")}_${spanNo}_b`];
        const email = `dana.lee${spanNo % 7}@fund.example`;
        const title = `Re: invoice ${4400 + (spanNo % 50)} for ${email} - ${spec.appName}`;
        const url = spec.host === "" ? "" : `https://${spec.host}/mail/u/0/#inbox/FMfcgz${spanNo}`;
        raw.titles.push(title);
        raw.emails.push(email);
        if (url !== "") raw.urls.push(url);
        raw.texts.push(`Hi Dana, following up on invoice ${4400 + (spanNo % 50)} due 2026-11-${String(1 + (spanNo % 28)).padStart(2, "0")}, total 1,${spanNo % 1000} USD`);
        raw.observationIds.push(...obs);
        spans.push({ id: sid, start: t, end: t + secs * 1000, activeSeconds: secs, appBundleId: spec.appBundleId, appName: spec.appName, host: spec.host, title, observationIds: obs });
        inst.spanIds.push(sid);
        inst.observationIds.push(...obs);
        inst.activeSeconds += secs;
        t += secs * 1000;
      }
      inst.end = t;
      task.instances.push(inst);
      t += pick(20, 90) * 1000;
    });
  });
  const list = [...tasks.values()].filter((x) => x.instances.length > 0);
  return { window: { timezone: opts.timezone ?? "UTC", days, spans, tasks: list }, raw, refOf };
}

/** The window task for a spec ref. */
export const taskOf = (w: FixtureWeek, ref: string): WindowTask => w.window.tasks.find((t) => w.refOf.get(t.id) === ref)!;
