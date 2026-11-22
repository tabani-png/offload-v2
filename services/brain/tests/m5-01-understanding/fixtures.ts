// Synthetic, masked observations for the m5-01 tests. Deterministic for a seed. Every app text, pseudonym and host is
// made up; pseudonyms have the device's shape (`<doc:h_…>`, 16 hex) but come from a fixed table, not a key.
// Shapes follow what the Mac sends (m1-02 contracts) and what the recordings import (m3-05) emits: `idle_end` at the
// start of a recording, a `focus` per app change, a `text_snapshot` per frame every 5 s, `idle_start` 120 s after the end.
import type { CaptureObservation, CaptureText } from "../../src/understanding/types.ts";

export const DEVICE = "0193a6f2-0000-7000-8000-0000000000d1";
export const IMPORT_ID = "0193a6f2-0000-7000-8000-0000000000e1";
const MIN = 60_000;

export function rng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const B32 = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
/** A valid ULID for `ts` with seeded randomness (the capture tables check the ULID shape). */
export function ulidAt(ts: number, r: () => number): string {
  let time = "";
  let t = ts;
  for (let i = 0; i < 10; i++) {
    time = B32[t % 32] + time;
    t = Math.floor(t / 32);
  }
  let rand = "";
  for (let i = 0; i < 16; i++) rand += B32[Math.floor(r() * 32)];
  return time + rand;
}

export const hex16 = (r: () => number) => Array.from({ length: 16 }, () => "0123456789abcdef"[Math.floor(r() * 16)]).join("");
export const doc = (r: () => number) => `<doc:h_${hex16(r)}>`;
export const person = (r: () => number) => `<person:h_${hex16(r)}>`;

export interface FrameApp {
  bundle: string;
  name: string;
  title?: string;
  host?: string;
  doc?: string;
}

/** One continuous stretch on one app; `frames` are the masked texts read every 5 s (empty for no text). */
export interface Segment {
  app: FrameApp;
  seconds: number;
  frames: string[];
}

export interface Recording {
  start: number;
  segments: Segment[];
  source?: "live" | "import";
}

export interface Built {
  observations: CaptureObservation[];
  texts: CaptureText[];
}

/** Observations for one recording (or one live stretch): idle_end, focus per segment, texts, idle_start + 120 s. */
export function recordingObservations(rec: Recording, r: () => number, deviceId = DEVICE): Built {
  const source = rec.source ?? "import";
  const importId = source === "import" ? IMPORT_ID : null;
  const observations: CaptureObservation[] = [];
  const texts: CaptureText[] = [];
  const obs = (ts: number, kind: CaptureObservation["kind"], app?: FrameApp): void => {
    observations.push({
      device_id: deviceId, object_id: ulidAt(ts, r), ts, kind,
      app_bundle_id: app?.bundle ?? null, app_name: app?.name ?? null, title: app?.title ?? null, host: app?.host ?? null,
      doc: app?.doc ?? null, keys: null, clicks: null, source, import_id: importId,
    });
  };
  obs(rec.start, "idle_end");
  let t = rec.start;
  let last = "";
  for (const seg of rec.segments) {
    // Like the Mac: a focus only when the app, title or host changes (a recording without a menu bar has one).
    const key = JSON.stringify(seg.app);
    if (key !== last) obs(t, "focus", seg.app);
    last = key;
    const n = Math.max(1, Math.floor(seg.seconds / 5));
    for (let i = 0; i < n; i++) {
      const text = seg.frames.length === 0 ? null : seg.frames[i % seg.frames.length]!;
      if (text === null) continue;
      const ts = t + i * 5000;
      texts.push({ device_id: deviceId, object_id: ulidAt(ts, r), ts, text, text_source: "ocr", app_bundle_id: seg.app.bundle });
    }
    t += seg.seconds * 1000;
  }
  obs(t + 120_000, "idle_start");
  return { observations, texts };
}

export function merge(parts: readonly Built[]): Built {
  return { observations: parts.flatMap((p) => p.observations), texts: parts.flatMap((p) => p.texts) };
}

// ---------- the repeated back-office workflow: an invoice from mail into the accounting app, then the log sheet ----------

const SUPPLIERS = 5;

/** One invoice instance: 3 steps (Mail, accounting web app in Chrome, Excel log), each naming the same invoice doc. */
export function invoiceSegments(r: () => number, opts: { menuBar?: boolean } = {}): Segment[] {
  const inv = doc(r);
  const supplier = `<person:h_${(Math.floor(r() * SUPPLIERS) + 1).toString(16).padStart(16, "a")}>`;
  const amount = `${Math.floor(r() * 9000) + 100}.${String(Math.floor(r() * 100)).padStart(2, "0")}`;
  const menu = opts.menuBar ?? true;
  const stand = { bundle: "recording.unknown", name: "Screen" };
  return [
    {
      app: menu ? { bundle: "com.apple.mail", name: "Mail", title: `Invoice ${inv} from ${supplier}`, doc: inv } : stand,
      seconds: 40,
      frames: [`Mail Inbox Invoice ${inv} from ${supplier} amount due ${amount} Download attachment`, `Invoice ${inv} ${supplier} Download PDF`],
    },
    {
      app: menu ? { bundle: "com.google.Chrome", name: "Google Chrome", title: "New bill - Ledgerly", host: "app.ledgerly.example" } : stand,
      seconds: 90,
      frames: [
        `Google Chrome app.ledgerly.example New bill Supplier ${supplier} Reference ${inv} Amount ${amount} Due date`,
        `Google Chrome app.ledgerly.example New bill Supplier ${supplier} Save and approve`,
      ],
    },
    {
      app: menu ? { bundle: "com.microsoft.Excel", name: "Microsoft Excel", title: "Supplier invoices log", doc: inv } : stand,
      seconds: 30,
      frames: [`Microsoft Excel Supplier invoices log ${inv} ${supplier} ${amount} entered`],
    },
  ];
}

/** Unrelated recordings without a menu bar (the stand-in clips): different content, no shared words. */
export const NOISE: readonly Segment[] = [
  { app: { bundle: "recording.unknown", name: "Screen" }, seconds: 45, frames: ["Google Chrome video.example Pasta recipe tomato basil garlic simmer", "video.example tomato basil sauce simmer minutes"] },
  { app: { bundle: "recording.unknown", name: "Screen" }, seconds: 50, frames: ["Quarterly roadmap planning slides milestones launch hiring", "roadmap milestones hiring launch timeline"] },
  { app: { bundle: "recording.unknown", name: "Screen" }, seconds: 40, frames: ["Travel vlog beach sunset drone footage island", "sunset beach island drone"] },
  { app: { bundle: "recording.unknown", name: "Screen" }, seconds: 35, frames: [] },
  { app: { bundle: "recording.unknown", name: "Screen" }, seconds: 30, frames: ["Keyboard review switches tactile linear sound test", "tactile switches sound"] },
];

/** UTC midnight of a day label. */
export const utc = (day: string): number => Date.parse(`${day}T00:00:00Z`);

/**
 * An import: `days` days of the invoice workflow (`perDay` instances per day, 30 min apart) plus the noise clips
 * spread between them (all within 15 min of a neighbour, so a naive sessionizer would merge them).
 */
export function invoiceImport(days: readonly string[], opts: { perDay?: number; seed?: number; menuBar?: boolean; noise?: boolean; source?: "live" | "import" } = {}): Built & { instances: number } {
  const r = rng(opts.seed ?? 7);
  const perDay = opts.perDay ?? 2;
  const parts: Built[] = [];
  let instances = 0;
  for (const day of days) {
    let t = utc(day) + 9 * 60 * MIN;
    for (let i = 0; i < perDay; i++) {
      const rec: Recording = { start: t, segments: invoiceSegments(r, opts.menuBar === undefined ? {} : { menuBar: opts.menuBar }), source: opts.source ?? "import" };
      parts.push(recordingObservations(rec, r));
      instances++;
      t += 30 * MIN;
    }
  }
  if (opts.noise ?? true) {
    // Noise on the first day, afternoon: back to back, 3 min apart.
    let t = utc(days[0]!) + 14 * 60 * MIN;
    for (const seg of NOISE) {
      parts.push(recordingObservations({ start: t, segments: [seg], source: opts.source ?? "import" }, r));
      t += seg.seconds * 1000 + 3 * MIN;
    }
  }
  return { ...merge(parts), instances };
}

// ---------- a working week for the ledger test: real apps, recurring tasks ----------

/** One weekday of live work: 2 invoices, a Slack reply stretch, the weekly report in Excel (Fri), code review. */
export function liveDay(day: string, r: () => number): Built {
  const parts: Built[] = [];
  let t = utc(day) + 8 * 60 * MIN;
  const live = (segments: Segment[]) => {
    parts.push(recordingObservations({ start: t, segments, source: "live" }, r));
    t += segments.reduce((n, s) => n + s.seconds, 0) * 1000 + 25 * MIN;
  };
  live(invoiceSegments(r));
  live([{ app: { bundle: "com.tinyspeck.slackmacgap", name: "Slack", title: "general - Acme" }, seconds: 180, frames: ["Slack general channel reply thread standup notes"] }]);
  live([{ app: { bundle: "com.microsoft.VSCode", name: "Code", title: "billing.ts - api" }, seconds: 600, frames: ["Pull request review comments approve changes diff billing"] }]);
  live(invoiceSegments(r));
  live([{ app: { bundle: "com.google.Chrome", name: "Google Chrome", title: "Pipeline - Dealbook", host: "crm.dealbook.example" }, seconds: 240, frames: ["Dealbook pipeline update deal stage contact notes follow up"] }]);
  return merge(parts);
}

export function liveWeek(monday: string, seed: number): Built {
  const r = rng(seed);
  const parts: Built[] = [];
  for (let i = 0; i < 5; i++) parts.push(liveDay(new Date(utc(monday) + i * 86_400_000).toISOString().slice(0, 10), r));
  return merge(parts);
}
