import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { Pool } from "pg";

export function databaseUrl(): string {
  const url = process.env["DATABASE_URL"];
  if (!url) throw new Error("DATABASE_URL is required (Postgres 17). See slices/m1-01-durable-spike/SPEC.md");
  return url;
}

export function newPool(url: string = databaseUrl()): Pool {
  return new Pool({ connectionString: url, max: 4 });
}

export async function waitFor<T>(what: string, probe: () => Promise<T | null | undefined | false>, timeoutMs = 20_000): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const v = await probe();
    if (v) return v;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 40));
  }
}

/** One line per execution; the count is the number of lines. */
export function bump(file: string, line = "ran"): void {
  appendFileSync(file, `${line}\n`);
}
export function count(file: string): number {
  return existsSync(file) ? readFileSync(file, "utf8").split("\n").filter(Boolean).length : 0;
}

/** A fake clock that tests move by hand. */
export function fakeClock(startMs: number): { now(): number; set(ms: number): void; advance(ms: number): void } {
  let t = startMs;
  return { now: () => t, set: (ms) => void (t = ms), advance: (ms) => void (t += ms) };
}

/** Same user name swapped into a postgres URL; the URL itself is never printed. */
export function withUser(url: string, user: string): string {
  const u = new URL(url);
  u.username = user;
  u.password = "";
  return u.toString();
}

export const TENANT_A = "0197a000-0000-7000-8000-00000000000a";
export const TENANT_B = "0197a000-0000-7000-8000-00000000000b";
