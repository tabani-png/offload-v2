/**
 * Database configuration. The retention TTLs live here and nowhere else (DATA_MODEL.md section 1, retention classes;
 * defaults from OQ-02). Values are read, never logged.
 */
export interface DbConfig {
  databaseUrl: string | undefined;
  /** R-raw: C1 metadata (observations). */
  rawTtlDays: number;
  /** R-text: C1 text snapshots (observation_texts). */
  textTtlDays: number;
  /** R-content: C6 connector content. */
  contentTtlDays: number;
}

const DEFAULT_TTL_DAYS = { OFFLOAD_RAW_TTL_DAYS: 30, OFFLOAD_TEXT_TTL_DAYS: 7, OFFLOAD_CONTENT_TTL_DAYS: 30 } as const;

function days(env: Record<string, string | undefined>, name: keyof typeof DEFAULT_TTL_DAYS): number {
  const raw = env[name];
  if (raw === undefined || raw === "") return DEFAULT_TTL_DAYS[name];
  if (!/^[0-9]{1,5}$/.test(raw) || Number(raw) < 1) throw new Error(`${name} must be a whole number of days, at least 1`);
  return Number(raw);
}

export function loadConfig(env: Record<string, string | undefined> = process.env): DbConfig {
  const url = env["DATABASE_URL"];
  return {
    databaseUrl: url === undefined || url === "" ? undefined : url,
    rawTtlDays: days(env, "OFFLOAD_RAW_TTL_DAYS"),
    textTtlDays: days(env, "OFFLOAD_TEXT_TTL_DAYS"),
    contentTtlDays: days(env, "OFFLOAD_CONTENT_TTL_DAYS"),
  };
}
