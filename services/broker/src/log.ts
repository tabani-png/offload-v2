/**
 * The broker's one logger (SECURITY_PRIVACY section 9). Logs ids and hashes only, and scrubs known secret patterns
 * from every string it is given, including base64 and URL-encoded forms. No other module writes to a log.
 */

const PATTERNS: RegExp[] = [
  /sk-ant-[A-Za-z0-9_-]{8,}/g,
  /\bsk-[A-Za-z0-9_-]{16,}/g,
  /\bgh[pousr]_[A-Za-z0-9]{16,}/g,
  /github_pat_[A-Za-z0-9_]{16,}/g,
  /\b(?:AKIA|ASIA)[A-Z0-9]{12,}/g,
  /\bxox[abprs]-[A-Za-z0-9-]{8,}/g,
  /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}/g,
  /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)/g,
  /\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}/gi,
  // KEY=value, "key": "value" for names that look like secrets.
  /\b([A-Za-z0-9_-]*(?:KEY|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL)[A-Za-z0-9_-]*)(["']?\s*[=:]\s*["']?)[^\s"',&;]{4,}/gi,
];

const REDACTED = "[redacted]";

function hasSecret(text: string): boolean {
  return PATTERNS.some((p) => ((p.lastIndex = 0), p.test(text)));
}

/** Replaces secret-looking text in `text`; also decodes percent-encoded and base64 runs and redacts a run whose decoded form matches. */
export function scrub(text: string): string {
  let out = text;
  for (const p of PATTERNS) {
    p.lastIndex = 0;
    out = out.replace(p, (_m, name?: string, sep?: string) => (typeof name === "string" && typeof sep === "string" ? `${name}${sep}${REDACTED}` : REDACTED));
  }
  out = out.replace(/(?:%[0-9A-Fa-f]{2}|[A-Za-z0-9._~-]){12,}/g, (run) => {
    if (!run.includes("%")) return run;
    try {
      return hasSecret(decodeURIComponent(run)) ? REDACTED : run;
    } catch {
      return run;
    }
  });
  out = out.replace(/[A-Za-z0-9+/_-]{20,}={0,2}/g, (run) => {
    try {
      const decoded = Buffer.from(run, run.includes("-") || run.includes("_") ? "base64url" : "base64").toString("utf8");
      return hasSecret(decoded) ? REDACTED : run;
    } catch {
      return run;
    }
  });
  return out;
}

export type LogFields = Record<string, string | number | boolean | null | undefined>;

export interface Logger {
  info(event: string, fields?: LogFields): void;
  warn(event: string, fields?: LogFields): void;
  error(event: string, fields?: LogFields): void;
}

/** `sink` receives one JSON line per event (default: stderr). */
export function createLogger(sink: (line: string) => void = (l) => process.stderr.write(`${l}\n`)): Logger {
  const emit = (level: string, event: string, fields: LogFields = {}) => {
    const clean: Record<string, unknown> = { level, event };
    for (const [k, v] of Object.entries(fields)) clean[k] = typeof v === "string" ? scrub(v) : v;
    sink(scrub(JSON.stringify(clean)));
  };
  return {
    info: (e, f) => emit("info", e, f),
    warn: (e, f) => emit("warn", e, f),
    error: (e, f) => emit("error", e, f),
  };
}
