// The claim connection of pgCaptureStore (review 3 finding 5): a stub pool, no database.
import { expect, test } from "bun:test";
import { pgCaptureStore } from "../../src/understanding/capture.ts";

type Released = { err: unknown; called: boolean };
function stubPool(opts: { lockOk: boolean; unlockFails: boolean }) {
  const released: Released = { err: undefined, called: false };
  let connects = 0;
  const pool = {
    connect: async () => {
      connects++;
      return {
        query: async (sql: string) => {
          if (sql.includes("pg_try_advisory_lock")) return { rows: [{ ok: opts.lockOk }] };
          if (sql.includes("pg_advisory_unlock") && opts.unlockFails) throw new Error("connection lost");
          return { rows: [{ ok: true }] };
        },
        release: (err?: unknown) => {
          released.called = true;
          released.err = err;
        },
      };
    },
  };
  return { pool: pool as never, released, connects: () => connects };
}

test("CONSUME: event claims come from the claim pool, and a connection whose unlock failed is destroyed", async () => {
  const main = stubPool({ lockOk: true, unlockFails: false });
  const claims = stubPool({ lockOk: true, unlockFails: true });
  const store = pgCaptureStore(main.pool, { claimPool: claims.pool });
  const got = await store.withEventLock("t", "e", async () => 42);
  expect(got).toEqual({ locked: true, value: 42 });
  expect(claims.connects()).toBe(1);
  expect(main.connects()).toBe(0);
  expect(claims.released.called).toBe(true);
  expect(claims.released.err).toBeInstanceOf(Error);

  const busy = stubPool({ lockOk: false, unlockFails: false });
  const other = pgCaptureStore(main.pool, { claimPool: busy.pool });
  let ran = false;
  expect(await other.withEventLock("t", "e", async () => { ran = true; })).toEqual({ locked: false });
  expect(ran).toBe(false);
  expect(busy.released.called).toBe(true);
  expect(busy.released.err).toBeUndefined();
});
