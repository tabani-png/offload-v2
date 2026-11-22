import { expect, test } from "bun:test";
import { buildUnderstandingWindow } from "../../src/understanding/window.ts";
import type { UnderstandingWindow } from "../../src/user-model/ports.ts";
import { invoiceImport, merge, recordingObservations, rng, utc, type Built, type Segment } from "./fixtures.ts";

const DAYS = ["2026-11-09", "2026-11-10", "2026-11-11"];
const win = (b: Built, days: string[] = DAYS) => buildUnderstandingWindow({ timezone: "UTC", days, observations: b.observations, texts: b.texts });
const spanApps = (w: UnderstandingWindow, ids: readonly string[]) => ids.map((id) => w.spans.find((s) => s.id === id)!.appBundleId);

test("INDUCE: a 3-step workflow repeated N times gives one task with N instances", async () => {
  for (const menuBar of [true, false]) {
    const fx = invoiceImport(DAYS, { perDay: 2, noise: false, menuBar });
    const w = await win(fx);
    expect(w.tasks).toHaveLength(1);
    const t = w.tasks[0]!;
    expect(t.instances).toHaveLength(fx.instances);
    expect(fx.instances).toBe(6);
    for (const i of t.instances) expect(spanApps(w, i.spanIds)).toEqual(["com.apple.mail", "com.google.Chrome", "com.microsoft.Excel"]);
    expect(t.centroid).toHaveLength(1024);
    expect(t.sameness).toBeGreaterThan(0.9);
    expect(t.kind).toMatch(/^[a-z]+\.[a-z]+(-[a-z]+)?$/);
    expect(t.name).toMatch(/invoice|bill/i);
  }
});

test("INDUCE: unrelated recordings do not merge into one task", async () => {
  const fx = invoiceImport(DAYS, { perDay: 2, noise: true, menuBar: false });
  const w = await win(fx);
  const invoice = w.tasks.filter((t) => t.instances.length > 1);
  expect(invoice).toHaveLength(1);
  expect(invoice[0]!.instances).toHaveLength(6);
  const noise = w.tasks.filter((t) => t.instances.length === 1);
  // Five noise clips: four with text (four tasks), one without text (no task).
  expect(noise).toHaveLength(4);
  for (const t of noise) expect(t.instances[0]!.spanIds).toHaveLength(1);
  const used = w.tasks.flatMap((t) => t.instances.flatMap((i) => i.spanIds));
  expect(new Set(used).size).toBe(used.length);
  expect(w.spans.length).toBe(used.length + 1);
});

const DOC_X = "<doc:h_aaaaaaaaaaaaaaaa>";
const DOC_Y = "<doc:h_bbbbbbbbbbbbbbbb>";
const app = (bundle: string, name: string, title: string, d?: string) => ({ bundle, name, title, ...(d === undefined ? {} : { doc: d }) });

test("INDUCE: steps sharing a doc pseudonym on different days join the same task", async () => {
  const r = rng(11);
  const b = merge([
    recordingObservations({ start: utc("2026-11-09") + 10 * 3_600_000, source: "live", segments: [{ app: app("com.apple.Preview", "Preview", `Contract ${DOC_X}`, DOC_X), seconds: 120, frames: [`Contract ${DOC_X} terms signature page`] }] }, r),
    recordingObservations({ start: utc("2026-11-10") + 10 * 3_600_000, source: "live", segments: [{ app: app("com.apple.mail", "Mail", `Re: contract ${DOC_X}`, DOC_X), seconds: 90, frames: [`Reply contract ${DOC_X} countersigned copy attached`] }] }, r),
    recordingObservations({ start: utc("2026-11-10") + 15 * 3_600_000, source: "live", segments: [{ app: app("com.apple.iWork.Numbers", "Numbers", `Budget ${DOC_Y}`, DOC_Y), seconds: 90, frames: ["Budget forecast quarter marketing spend"] }] }, r),
  ]);
  const w = await win(b, ["2026-11-09", "2026-11-10"]);
  const withDoc = w.tasks.filter((t) => t.instances.some((i) => spanApps(w, i.spanIds).includes("com.apple.Preview")));
  expect(withDoc).toHaveLength(1);
  const apps = withDoc[0]!.instances.flatMap((i) => spanApps(w, i.spanIds)).sort();
  expect(apps).toEqual(["com.apple.Preview", "com.apple.mail"]);
  expect(withDoc[0]!.instances).toHaveLength(2);
  expect(w.tasks).toHaveLength(2);
});

test("INDUCE: instances split on a new day, a gap over 10 min and a conflicting doc pseudonym", async () => {
  const r = rng(12);
  const A = (d: string): Segment => ({ app: app("com.apple.mail", "Mail", `Order ${d}`, d), seconds: 60, frames: [`Order ${d} from customer`] });
  const B = (d: string): Segment => ({ app: { bundle: "com.google.Chrome", name: "Google Chrome", title: "Orders", host: "shop.example", doc: d }, seconds: 60, frames: [`Create order ${d} shop`] });
  const at = (day: string, min: number) => utc(day) + 9 * 3_600_000 + min * 60_000;
  const d1 = "<doc:h_1111111111111111>", d2 = "<doc:h_2222222222222222>", d3 = "<doc:h_3333333333333333>", d4 = "<doc:h_4444444444444444>";
  const d5 = "<doc:h_5555555555555555>", d6 = "<doc:h_6666666666666666>";
  const b = merge([
    recordingObservations({ start: at("2026-11-09", 0), source: "live", segments: [A(d1), B(d1), A(d2), B(d2)] }, r), // start step recurs: 2
    recordingObservations({ start: at("2026-11-09", 30), source: "live", segments: [A(d3), B(d3)] }, r), // gap over 10 min: 1
    recordingObservations({ start: at("2026-11-10", 0), source: "live", segments: [A(d4), B(d4)] }, r), // new day: 1
    recordingObservations({ start: at("2026-11-10", 30), source: "live", segments: [A(d5), B(d6)] }, r), // conflicting doc: 2
  ]);
  const w = await win(b, ["2026-11-09", "2026-11-10"]);
  expect(w.tasks).toHaveLength(1);
  const sizes = w.tasks[0]!.instances.map((i) => spanApps(w, i.spanIds).map((a) => (a === "com.apple.mail" ? "A" : "B")).join(""));
  expect(sizes).toEqual(["AB", "AB", "AB", "AB", "A", "B"]);
});
