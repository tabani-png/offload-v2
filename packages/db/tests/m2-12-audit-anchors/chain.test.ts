import { afterAll, beforeAll, expect, test } from "bun:test";
import { pgTenantFixture, type PgTenantFixture } from "@offload/testkit";
import { fakeSigner } from "@offload/testkit/src/audit/index.ts";
import { verifyChain, withTenant, writeAnchor, uuidv7, type TenantContext } from "../../src/index.ts";
import { appendN, newTenant, tamper } from "./helpers.ts";

let fx: PgTenantFixture;
beforeAll(async () => {
  fx = await pgTenantFixture({ appPoolSize: 6 });
});
afterAll(async () => {
  await fx?.close();
});

const verify = (ctx: TenantContext, signer = fakeSigner()) => withTenant(fx.app, ctx, (tx) => verifyChain(tx, ctx.tenantId, signer));

/** A tenant with tenant.created plus three events: four rows. */
async function four(): Promise<TenantContext> {
  const ctx = await newTenant(fx.app);
  await appendN(fx.app, ctx, 3);
  return ctx;
}

test("AUDIT: verify detects an edited event, a deleted event and a fork", async () => {
  const signer = fakeSigner();

  const edited = await four();
  await tamper(fx, edited.tenantId, async (c) => {
    await c.query("update audit_events set details = '{\"i\": 9}' where tenant_id = $1 and seq = 3", [edited.tenantId]);
  });
  expect(await verify(edited, signer)).toEqual({ ok: false, checked: 4, first_bad_seq: 3, reason: "hash_mismatch" });

  const deleted = await four();
  await tamper(fx, deleted.tenantId, async (c) => {
    await c.query("delete from audit_events where tenant_id = $1 and seq = 2", [deleted.tenantId]);
  });
  expect(await verify(deleted, signer)).toEqual({ ok: false, checked: 3, first_bad_seq: 3, reason: "seq_gap" });

  // A fork: with UNIQUE (tenant_id, prev_hash) dropped, a second row names the same prev_hash as seq 2.
  const forked = await four();
  const seq1 = (await fx.admin.query("select hash from audit_events where tenant_id = $1 and seq = 1", [forked.tenantId])).rows[0].hash as string;
  const constraint = "audit_events_tenant_id_prev_hash_key";
  await tamper(fx, forked.tenantId, async (c) => {
    await c.query(`alter table audit_events drop constraint ${constraint}`);
    await c.query(
      `insert into audit_events (tenant_id, seq, id, at, principal_id, action, details, prev_hash, hash)
       values ($1, 5, '01JC0000000000000000000009', now(), 'p', 'batch.committed', '{}', $2, $3)`,
      [forked.tenantId, seq1, "b".repeat(64)],
    );
  });
  try {
    expect(await verify(forked, signer)).toEqual({ ok: false, checked: 5, first_bad_seq: 5, reason: "prev_hash_mismatch" });
  } finally {
    await tamper(fx, forked.tenantId, async (c) => {
      await c.query("delete from audit_events where tenant_id = $1 and seq = 5", [forked.tenantId]);
      await c.query(`alter table audit_events add constraint ${constraint} unique (tenant_id, prev_hash)`);
    });
  }
  expect(await verify(forked, signer)).toEqual({ ok: true, checked: 4 });
});

test("AUDIT: an untouched chain of 50 events verifies with checked 50", async () => {
  const ctx = await newTenant(fx.app);
  await appendN(fx.app, ctx, 49);
  expect(await verify(ctx)).toEqual({ ok: true, checked: 50 });
});

test("AUDIT: an empty chain verifies with checked 0", async () => {
  const ctx: TenantContext = { tenantId: uuidv7(), principalId: "p", memberId: null, tenantRole: "auditor" };
  expect(await verify(ctx)).toEqual({ ok: true, checked: 0 });
});

test("VERIFY: an anchor whose head_hash no longer matches its event fails verify", async () => {
  const signer = fakeSigner();
  const ctx = await four();
  const a = await withTenant(fx.app, ctx, (tx) => writeAnchor(tx, ctx.tenantId, signer, new Date("2026-11-14T10:00:00.000Z")));
  expect(a?.seq).toBe(4);
  expect(await verify(ctx, signer)).toEqual({ ok: true, checked: 4 });
  await tamper(fx, ctx.tenantId, async (c) => {
    await c.query("update audit_anchors set head_hash = $2 where tenant_id = $1", [ctx.tenantId, "f".repeat(64)]);
  }, "audit_anchors");
  expect(await verify(ctx, signer)).toEqual({ ok: false, checked: 4, first_bad_seq: 4, reason: "anchor_mismatch" });
});

test("VERIFY: an anchor with a bad signature fails verify", async () => {
  const signer = fakeSigner();
  const ctx = await four();
  await withTenant(fx.app, ctx, (tx) => writeAnchor(tx, ctx.tenantId, signer, new Date("2026-11-14T10:00:00.000Z")));
  // Another key's signature over the same bytes, an unknown key id, and an edited signed_at each fail.
  const other = fakeSigner();
  const row = (await fx.admin.query("select signature from audit_anchors where tenant_id = $1", [ctx.tenantId])).rows[0];
  expect(row.signature).toMatch(/^[A-Za-z0-9_-]+$/);
  expect(await verify(ctx, other)).toEqual({ ok: false, checked: 4, first_bad_seq: 4, reason: "anchor_signature" });
  await tamper(fx, ctx.tenantId, async (c) => {
    await c.query("update audit_anchors set signed_at = signed_at + interval '1 second' where tenant_id = $1", [ctx.tenantId]);
  }, "audit_anchors");
  expect(await verify(ctx, signer)).toEqual({ ok: false, checked: 4, first_bad_seq: 4, reason: "anchor_signature" });
});
