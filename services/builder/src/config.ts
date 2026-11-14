// Builder configuration. Numbers live here, never in queries ([ADR 0012], [ADR 0030]). Money is integer
// ten-thousandths of a USD (numeric(10,4) in Postgres): 40_000 = $4.00.
export interface BuildConfig {
  /** The build cap per OK, build ($4.00, owner decision). */
  cap_usd4: number;
  /** Held back from workers for check runs (teeth gate and verification shards): $0.30 (old s35 CHECKS_RESERVE_USD). */
  checks_reserve_usd4: number;
  /** One worker attempt's cap, pre-allocated before it starts ($0.70, ADR 0030). */
  attempt_cap_usd4: number;
  /** More workers on a check failure: 1 in M2, 3 from M6 (ADR 0012). Allowed 1 to 3. */
  fanout_workers: number;
  /** Tries inside one attempt, with the frozen check output fed back (ADR 0012: 2). */
  tries_per_attempt: number;
  /** Stop an attempt whose failing artifact did not change between two tries (craft-anything's idea, s35). */
  stop_on_stall: boolean;
  worker_wall_ms: number;
  verify_wall_ms: number;
  /** A live build with no progress for this long was left by a dead orchestrator (old SESSION_MAX_MS). */
  stale_after_ms: number;
  /** The prebuilt image with a pinned dependency set (spike S4 pins it by digest). */
  image: string;
}

export class ConfigError extends Error {}

const MIN = 60_000;
const WORKER_WALL_MS = 12 * MIN;
const VERIFY_WALL_MS = 5 * MIN;

export const DEFAULT_BUILD_CONFIG: Readonly<BuildConfig> = Object.freeze({
  cap_usd4: 40_000,
  checks_reserve_usd4: 3_000,
  attempt_cap_usd4: 7_000,
  fanout_workers: 1,
  tries_per_attempt: 2,
  stop_on_stall: true,
  worker_wall_ms: WORKER_WALL_MS,
  verify_wall_ms: VERIFY_WALL_MS,
  // Twice the longest stage without a heartbeat: one worker attempt at full wall time plus its verification.
  stale_after_ms: 2 * (WORKER_WALL_MS + VERIFY_WALL_MS),
  image: "oven/bun:1.4.4",
});

export function buildConfig(over: Partial<BuildConfig> = {}): BuildConfig {
  const c: BuildConfig = { ...DEFAULT_BUILD_CONFIG, ...over };
  const int = (k: keyof BuildConfig, min: number, max: number) => {
    const v = c[k];
    if (typeof v !== "number" || !Number.isInteger(v) || v < min || v > max) throw new ConfigError(`${k} must be an integer from ${min} to ${max}`);
  };
  int("fanout_workers", 1, 3);
  int("tries_per_attempt", 1, 5);
  int("cap_usd4", 1, 1_000_000);
  int("checks_reserve_usd4", 0, c.cap_usd4);
  int("attempt_cap_usd4", 1, c.cap_usd4);
  int("worker_wall_ms", 1, 3_600_000);
  int("verify_wall_ms", 1, 3_600_000);
  if (c.stale_after_ms < 2 * (c.worker_wall_ms + c.verify_wall_ms)) throw new ConfigError("stale_after_ms must cover a worker attempt and its verification twice");
  if (typeof c.image !== "string" || c.image === "") throw new ConfigError("image is required");
  return c;
}

/** "4.0000" for 40_000: the exact form bound into an approval. */
export const usd4Text = (n: number) => `${Math.trunc(n / 10_000)}.${String(Math.abs(n % 10_000)).padStart(4, "0")}`;
/** 4.00 → 40_000. Refuses more than 4 decimals. */
export function toUsd4(usd: number): number | null {
  if (typeof usd !== "number" || !Number.isFinite(usd) || usd < 0) return null;
  const n = Math.round(usd * 10_000);
  return Math.abs(n - usd * 10_000) < 1e-6 ? n : null;
}
export const fromUsd4 = (n: number) => n / 10_000;
