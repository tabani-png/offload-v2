import { afterAll, beforeAll, expect, test } from "bun:test";
import { onBeforeCommit } from "@offload/testkit";
import { envelope, focus, makeHarness, receiptOf, type Harness } from "./harness.ts";

let h: Harness;
beforeAll(async () => {
  h = await makeHarness();
});
afterAll(async () => {
  await h?.close();
});

test("OUTBOX: observations.ingested is written in the same transaction", async () => {
  const dev = await h.device(h.fx.a, h.fx.a.owner);
  await h.consent(dev);
  const outbox = async () =>
    (await h.fx.admin.query("select type, version, payload from events_outbox where tenant_id = $1 and payload->>'device_id' = $2", [dev.tenant.tenantId, dev.deviceId])).rows;
  const env = envelope(h, dev, 1, [focus(h), focus(h, { app_name: "Notes", app_bundle_id: "com.apple.Notes" })]);

  // Fault injection: the outbox row is in the transaction when COMMIT is about to run; throwing rolls everything back.
  const remove = onBeforeCommit(async (tx) => {
    const n = (await tx.query("select count(*)::int as n from events_outbox where payload->>'device_id' = $1", [dev.deviceId])).rows[0].n;
    if (n > 0) throw new Error("injected failure before commit");
  });
  let failed: Response;
  try {
    failed = await h.ingest(dev, env);
  } finally {
    remove();
  }
  expect(failed.status).toBe(500);
  expect(await h.count("observations", dev)).toBe(0);
  expect(await h.count("ingest_batches", dev)).toBe(0);
  expect(await outbox()).toEqual([]);
  expect((await h.fx.admin.query("select last_seq::int as s from devices where id = $1", [dev.deviceId])).rows[0].s).toBe(0);

  // The same bytes go through afterwards, and observations, batch row and event all exist together.
  const ok = await h.ingest(dev, env);
  expect(ok.status).toBe(200);
  expect((await receiptOf(ok)).accepted).toHaveLength(2);
  expect(await h.count("observations", dev)).toBe(2);
  expect(await h.count("ingest_batches", dev)).toBe(1);
  const rows = await outbox();
  expect(rows).toHaveLength(1);
  expect(rows[0]).toMatchObject({ type: "observations.ingested", version: 1, payload: { device_id: dev.deviceId, member_id: dev.memberId, seq: 1, accepted: 2 } });
});
