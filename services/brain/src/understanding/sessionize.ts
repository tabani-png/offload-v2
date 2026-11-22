// Sessionize (SPAN): observations -> spans. Written fresh after old brain/src/sessionize.ts for v2's observations.
// A segment ends at the next focus, idle_start (backdated: the Mac writes it 120 s after the last input), pause or the
// last event. Text snapshots and input counts attach to the segment open at their time. Segments on a stand-in app
// split where the masked text shows another app or host (cues.ts). Blips under 10 s join a contiguous neighbour;
// segments with the same app + title + host merge across idle up to 15 min, except stand-in segments without a cue,
// which have nothing to say they are the same work. Pure: same rows in (any order), same spans out.
import { cueOf, isStandInApp, type Cue } from "./cues.ts";
import { uuidFrom } from "./ids.ts";
import type { CaptureObservation, CaptureText, Span } from "./types.ts";

export interface SessionOptions {
  /** Segments shorter than this are blips and join a neighbour. */
  minSpanMs: number;
  /** Two segments of one focus split only by idle merge when the idle gap is at most this long. */
  idleMergeMaxMs: number;
  /** How long after the last input the Mac writes idle_start. */
  idleBackdateMs: number;
}

export const SESSION: Readonly<SessionOptions> = { minSpanMs: 10_000, idleMergeMaxMs: 15 * 60_000, idleBackdateMs: 120_000 };

interface Focus {
  app: string;
  appName: string;
  title: string;
  host: string;
  doc: string | null;
  /** The focus observation and its time (evidence for a segment re-opened after idle). */
  id: string;
  ts: number;
  standIn: boolean;
}

interface Ref {
  id: string;
  ts: number;
}

interface Segment {
  focus: Focus;
  /** The observation that opened it (unique per segment: a focus, an idle_end or the text that showed a new cue). */
  opener: string;
  start: number;
  end: number;
  refs: Ref[];
  texts: Array<Ref & { text: string }>;
  inputs: Array<Ref & { keys: number; clicks: number }>;
  cued: boolean;
}

type Event =
  | { kind: CaptureObservation["kind"]; id: string; ts: number; o: CaptureObservation }
  | { kind: "text"; id: string; ts: number; t: CaptureText };

const byTime = (a: { ts: number; id: string }, b: { ts: number; id: string }) => a.ts - b.ts || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

function focusOf(o: CaptureObservation): Focus {
  const app = o.app_bundle_id ?? "unknown";
  const appName = o.app_name ?? app;
  return { app, appName, title: o.title ?? "", host: o.host ?? "", doc: o.doc, id: o.object_id, ts: o.ts, standIn: isStandInApp(app, appName) };
}

/** Pass 1: one device's events -> raw segments. */
function toSegments(events: readonly Event[], idleBackdateMs: number): Segment[] {
  const out: Segment[] = [];
  let cur: Segment | null = null;
  let last: Focus | null = null;
  let paused = false;

  const cut = (s: Segment, at: number) => {
    s.end = Math.max(s.start, Math.min(s.end, at));
    s.texts = s.texts.filter((x) => x.ts < s.end || x.ts === s.start);
    s.inputs = s.inputs.filter((x) => x.ts < s.end || x.ts === s.start);
  };
  const close = (at: number) => {
    if (cur === null) return;
    cur.end = Math.max(cur.start, at);
    cut(cur, at);
    out.push(cur);
    cur = null;
  };
  const open = (focus: Focus, ts: number, opener: string, refs: Ref[]) => {
    cur = { focus, opener, start: ts, end: ts, refs, texts: [], inputs: [], cued: false };
  };

  for (const e of events) {
    switch (e.kind) {
      case "focus":
        close(e.ts);
        last = focusOf(e.o);
        if (!paused) open(last, e.ts, e.id, [{ id: e.id, ts: e.ts }]);
        break;
      case "idle_start": {
        // Input stopped idleBackdateMs before the Mac noticed: nothing after that moment is active.
        const cutoff = e.ts - idleBackdateMs;
        const c = cur as Segment | null;
        if (c !== null && cutoff <= c.start && c.texts.length === 0 && c.inputs.length === 0 && c.opener !== c.focus.id) cur = null;
        close(cutoff);
        for (let i = out.length - 1; i >= 0; i--) {
          const seg = out[i]!;
          if (seg.end <= cutoff) break;
          cut(seg, cutoff);
        }
        break;
      }
      case "idle_end":
        if (!paused && cur === null && last !== null) open(last, e.ts, e.id, [{ id: last.id, ts: last.ts }, { id: e.id, ts: e.ts }]);
        break;
      case "pause":
        close(e.ts);
        paused = true;
        last = null;
        break;
      case "resume":
        // Focus during the pause is unknown: nothing counts until the next focus.
        paused = false;
        break;
      case "input_counts":
        if (cur !== null) (cur as Segment).inputs.push({ id: e.id, ts: e.ts, keys: e.o.keys ?? 0, clicks: e.o.clicks ?? 0 });
        break;
      case "text":
        if (cur !== null) (cur as Segment).texts.push({ id: e.id, ts: e.ts, text: e.t.text });
        break;
      case "permission_change":
        break;
    }
  }
  const lastEvent = events[events.length - 1];
  if (lastEvent !== undefined) close(lastEvent.ts);
  return out;
}

/** A stand-in segment splits where its text shows another app or host; texts without a cue keep the running one. */
function applyCues(seg: Segment): Segment[] {
  if (!seg.focus.standIn) return [seg];
  const parts: Segment[] = [];
  let running: Cue | null = null;
  let part: Segment = seg;
  const withCue = (s: Segment, c: Cue | null): Segment => {
    if (c === null || (c.appBundleId === undefined && c.host === undefined)) return s;
    return {
      ...s,
      cued: true,
      focus: { ...s.focus, app: c.appBundleId ?? s.focus.app, appName: c.appName ?? s.focus.appName, host: c.host ?? s.focus.host },
    };
  };
  const texts = seg.texts;
  part = { ...seg, texts: [], inputs: [] };
  for (const t of texts) {
    const c = cueOf(t.text);
    const found = c.appBundleId !== undefined || c.host !== undefined;
    if (found && running !== null && ((c.appBundleId !== undefined && c.appBundleId !== running.appBundleId) || (c.host !== undefined && c.host !== running.host)) && t.ts > part.start) {
      // A new app or host on screen: the part so far ends here and a new one starts at this text.
      parts.push(withCue({ ...part, end: t.ts }, running));
      part = { ...seg, opener: t.id, start: t.ts, refs: [], texts: [], inputs: [] };
      running = c.appBundleId !== undefined && c.appBundleId !== running.appBundleId ? c : { ...running, ...c };
    } else if (found) {
      running = running === null ? c : c.appBundleId !== undefined && c.appBundleId !== running.appBundleId ? c : { ...running, ...c };
    }
    part.texts.push(t);
  }
  parts.push(withCue({ ...part, end: seg.end }, running));
  for (const p of parts) p.inputs = seg.inputs.filter((x) => x.ts >= p.start && (x.ts < p.end || p === parts[parts.length - 1]));
  return parts;
}

interface Building {
  seed: Segment;
  focus: Focus;
  start: number;
  end: number;
  activeMs: number;
  refs: Map<string, number>;
  texts: Array<Ref & { text: string }>;
  docs: Set<string>;
  keys: number;
  clicks: number;
  cued: boolean;
}

function build(s: Segment): Building {
  const b: Building = { seed: s, focus: s.focus, start: s.start, end: s.end, activeMs: s.end - s.start, refs: new Map(), texts: [], docs: new Set(), keys: 0, clicks: 0, cued: s.cued };
  add(b, s);
  return b;
}

function add(b: Building, s: Segment): void {
  for (const r of s.refs) b.refs.set(r.id, r.ts);
  for (const t of s.texts) {
    b.refs.set(t.id, t.ts);
    b.texts.push(t);
  }
  for (const i of s.inputs) {
    b.refs.set(i.id, i.ts);
    b.keys += i.keys;
    b.clicks += i.clicks;
  }
  if (s.focus.doc !== null) b.docs.add(s.focus.doc);
}

function absorb(into: Building, s: Segment): void {
  into.start = Math.min(into.start, s.start);
  into.end = Math.max(into.end, s.end);
  into.activeMs += s.end - s.start;
  add(into, s);
}

/** Same app, title and host. A stand-in segment without a cue matches only itself. */
function keyOf(s: Segment): string {
  const f = s.focus;
  const base = `${f.app}\u0000${f.title}\u0000${f.host}`;
  return f.standIn && !s.cued ? `${base}\u0000${s.opener}` : base;
}

/** Pass 2: blips join a contiguous neighbour; one focus split only by idle up to idleMergeMaxMs is one span. */
function mergeSegments(segments: readonly Segment[], opts: SessionOptions): Building[] {
  const out: Building[] = [];
  let pending: Segment | null = null;
  for (const seg of segments) {
    const prev = out[out.length - 1];
    if (seg.end - seg.start < opts.minSpanMs) {
      if (prev !== undefined && prev.end === seg.start) absorb(prev, seg);
      else if (pending === null) pending = seg;
      else {
        const holder = build(pending);
        absorb(holder, seg);
        pending = null;
        out.push(holder);
      }
      continue;
    }
    const span = build(seg);
    if (pending !== null) {
      if (pending.end === seg.start) absorb(span, pending);
      else out.push(build(pending));
      pending = null;
    }
    const lastB = out[out.length - 1];
    if (lastB !== undefined && keyOf(lastB.seed) === keyOf(seg) && seg.start - lastB.end <= opts.idleMergeMaxMs && seg.start >= lastB.end) {
      absorb(lastB, seg);
      continue;
    }
    out.push(span);
  }
  if (pending !== null) out.push(build(pending));
  return out;
}

function toSpan(deviceId: string, b: Building): Span {
  const refs = [...b.refs.entries()].map(([id, ts]) => ({ id, ts })).sort(byTime);
  return {
    id: uuidFrom("span", deviceId, b.seed.opener),
    deviceId,
    start: b.start,
    end: b.end,
    activeMs: b.activeMs,
    appBundleId: b.focus.app,
    appName: b.focus.appName,
    title: b.focus.title,
    host: b.focus.host,
    docs: [...b.docs].sort(),
    observationIds: refs.map((r) => r.id),
    texts: [...b.texts].sort(byTime).map((t) => t.text),
    keys: b.keys,
    clicks: b.clicks,
    standIn: b.focus.standIn,
    cued: b.cued,
  };
}

export function sessionize(observations: readonly CaptureObservation[], texts: readonly CaptureText[], opts: SessionOptions = SESSION): Span[] {
  const byDevice = new Map<string, Event[]>();
  const push = (device: string, e: Event) => {
    const list = byDevice.get(device) ?? [];
    list.push(e);
    byDevice.set(device, list);
  };
  for (const o of observations) push(o.device_id, { kind: o.kind, id: o.object_id, ts: o.ts, o });
  for (const t of texts) push(t.device_id, { kind: "text", id: t.object_id, ts: t.ts, t });
  const spans: Span[] = [];
  for (const device of [...byDevice.keys()].sort()) {
    const events = byDevice.get(device)!.sort(byTime);
    const segments = toSegments(events, opts.idleBackdateMs).flatMap(applyCues);
    spans.push(...mergeSegments(segments, opts).map((b) => toSpan(device, b)));
  }
  return spans.sort((a, b) => a.start - b.start || (a.id < b.id ? -1 : 1));
}
