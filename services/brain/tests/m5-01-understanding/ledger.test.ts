import { expect, test } from "bun:test";
import { buildUnderstandingWindow } from "../../src/understanding/window.ts";
import { resolveTaskKeys } from "../../src/user-model/ledger.ts";
import { liveWeek } from "./fixtures.ts";

const days = (monday: string) => Array.from({ length: 7 }, (_, i) => new Date(Date.parse(`${monday}T00:00:00Z`) + i * 86_400_000).toISOString().slice(0, 10));

test("LEDGER: two fixture weeks of the same work keep at least 95% of task keys", async () => {
  const w1 = liveWeek("2026-11-02", 1);
  const w2 = liveWeek("2026-11-09", 2);
  const a = await buildUnderstandingWindow({ timezone: "UTC", days: days("2026-11-02"), observations: w1.observations, texts: w1.texts });
  const b = await buildUnderstandingWindow({ timezone: "UTC", days: days("2026-11-09"), observations: w2.observations, texts: w2.texts });
  expect(a.tasks.length).toBeGreaterThanOrEqual(4);
  expect(b.tasks.length).toBe(a.tasks.length);
  const first = resolveTaskKeys([], a);
  const second = resolveTaskKeys(first.ledger, b);
  const old = new Set(first.ledger.map((e) => e.taskKey));
  const kept = b.tasks.filter((t) => old.has(second.keys.get(t.id)!)).length;
  expect(kept / b.tasks.length).toBeGreaterThanOrEqual(0.95);
  const invoice = b.tasks.find((t) => t.instances.length === 10);
  expect(invoice).toBeDefined();
});
