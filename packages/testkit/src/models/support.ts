/**
 * Small router test ports (m5-03): recordingAudit, fakeClock, recordingLog and fakeLeakScanner.
 *
 * fakeLeakScanner is a stand-in for m3-01's transport check (`packages/masking/src/detectors.ts`), which has not landed
 * on this branch. It covers only the detectors the router tests use (email, Luhn card number, sk-ant / sk- keys) with
 * the same output shape ({ detector }). The composition root wires the real transport check, never this fake.
 */

export interface RecordedAuditEvent {
  tenant_id: string;
  principalId: string;
  action: string;
  subjectType?: string;
  subjectId?: string;
  details: Record<string, unknown>;
}

export function recordingAudit(): { events: RecordedAuditEvent[]; append(tenant_id: string, e: Omit<RecordedAuditEvent, "tenant_id">): Promise<void> } {
  const events: RecordedAuditEvent[] = [];
  return {
    events,
    async append(tenant_id, e) {
      events.push({ tenant_id, ...structuredClone(e) });
    },
  };
}

export function fakeClock(start: string | Date = "2026-11-14T12:00:00.000Z"): { now(): Date; advance(ms: number): void; set(at: string | Date): void } {
  let t = new Date(start).getTime();
  return {
    now: () => new Date(t),
    advance: (ms) => {
      t += ms;
    },
    set: (at) => {
      t = new Date(at).getTime();
    },
  };
}

export function recordingLog(): { lines: Array<Record<string, unknown>>; log(line: Record<string, unknown>): void } {
  const lines: Array<Record<string, unknown>> = [];
  return { lines, log: (line) => lines.push(structuredClone(line)) };
}

const SKIP_RE = /<(person|email|phone|doc):h_[0-9a-f]{16}>|<person:[a-z]{4}\.(\d+(\.first)?|me)>|<name>/g;
const EMAIL_RE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/;
const KEY_RE = /\bsk-(ant-)?[A-Za-z0-9_-]{16,}/;
const CARD_CANDIDATE_RE = /\b(?:\d[ -]?){12,18}\d\b/g;

function luhn(digits: string): boolean {
  let sum = 0;
  let double = false;
  for (let i = digits.length - 1; i >= 0; i--) {
    let d = digits.charCodeAt(i) - 48;
    if (double) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    double = !double;
  }
  return sum % 10 === 0;
}

export function fakeLeakScanner(): { scan(text: string): Array<{ detector: string }> } {
  return {
    scan(text) {
      const t = text.replace(SKIP_RE, " ");
      const hits: Array<{ detector: string }> = [];
      if (EMAIL_RE.test(t)) hits.push({ detector: "email" });
      if (KEY_RE.test(t)) hits.push({ detector: "api_key" });
      for (const m of t.matchAll(CARD_CANDIDATE_RE)) {
        const digits = m[0].replace(/[ -]/g, "");
        if (digits.length >= 13 && digits.length <= 19 && luhn(digits)) {
          hits.push({ detector: "card_number" });
          break;
        }
      }
      return hits;
    },
  };
}
