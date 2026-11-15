/** Minimal 5-field cron (minute hour day-of-month month day-of-week), UTC. No dependency. */

export interface CronSpec {
  minute: Set<number>;
  hour: Set<number>;
  dom: Set<number>;
  month: Set<number>;
  dow: Set<number>;
  domAny: boolean;
  dowAny: boolean;
}

function field(text: string, lo: number, hi: number, what: string): { set: Set<number>; any: boolean } {
  const set = new Set<number>();
  let any = false;
  for (const part of text.split(",")) {
    const m = /^(\*|\d+(?:-\d+)?)(?:\/(\d+))?$/.exec(part);
    if (!m) throw new Error(`invalid cron ${what}: "${text}"`);
    const [, range, stepText] = m as unknown as [string, string, string | undefined];
    const step = stepText === undefined ? 1 : Number(stepText);
    if (step < 1) throw new Error(`invalid cron ${what} step: "${text}"`);
    let a = lo;
    let b = hi;
    if (range !== "*") {
      const [x, y] = range.split("-").map(Number) as [number, number | undefined];
      a = x;
      b = y ?? (stepText === undefined ? x : hi);
    } else if (stepText === undefined) any = true;
    if (a < lo || b > hi || a > b) throw new Error(`cron ${what} out of range ${lo}-${hi}: "${text}"`);
    for (let v = a; v <= b; v += step) set.add(v);
  }
  return { set, any };
}

export function parseCron(expr: string): CronSpec {
  const parts = expr.trim().split(/\s+/);
  if (parts.length !== 5) throw new Error(`cron needs 5 fields, got ${parts.length}: "${expr}"`);
  const [mi, h, d, mo, w] = parts as [string, string, string, string, string];
  const dow = field(w, 0, 7, "day-of-week");
  if (dow.set.has(7)) dow.set.add(0);
  const dom = field(d, 1, 31, "day-of-month");
  return {
    minute: field(mi, 0, 59, "minute").set,
    hour: field(h, 0, 23, "hour").set,
    dom: dom.set,
    month: field(mo, 1, 12, "month").set,
    dow: dow.set,
    domAny: dom.any,
    dowAny: dow.any,
  };
}

export function cronMatches(spec: CronSpec, epochMs: number): boolean {
  const d = new Date(epochMs);
  if (!spec.minute.has(d.getUTCMinutes()) || !spec.hour.has(d.getUTCHours()) || !spec.month.has(d.getUTCMonth() + 1)) return false;
  const domOk = spec.dom.has(d.getUTCDate());
  const dowOk = spec.dow.has(d.getUTCDay());
  // Standard cron: when both day fields are restricted, either may match.
  if (!spec.domAny && !spec.dowAny) return domOk || dowOk;
  return domOk && dowOk;
}
