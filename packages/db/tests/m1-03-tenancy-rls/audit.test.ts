import { afterAll, beforeAll, expect, test } from "bun:test";
import { jcs, sha256Hex } from "@offload/contracts";
import {
  AUDIT_GENESIS_HASH, AuditEventError, appendAudit, createPersonalTenant, uuidv7, verifyAuditChain, withTenant, withTransaction,
  type TenantContext,
} from "../../src/index.ts";
import { onBeforeCommit, pgTenantFixture, type PgTenantFixture } from "@offload/testkit";

let fx: PgTenantFixture;
beforeAll(async () => {
  fx = await pgTenantFixture({ appPoolSize: 12 });
});
afterAll(async () => {
  await fx?.close();
});

const fail = (p: Promise<unknown>) => p.then(() => null, (e: Error) => e);

/** A fresh personal tenant, so every test starts its own chain. */
async function newTenant(): Promise<TenantContext> {
  const t = await withTransaction(fx.app, (tx) => createPersonalTenant(tx, { idpSubject: `oidc|${uuidv7()}`, email: "a@example.test" }));
  return { tenantId: t.tenantId, principalId: t.memberId, memberId: t.memberId, tenantRole: "owner" };
}

async function rows(ctx: TenantContext) {
  return withTenant(fx.app, ctx, async (tx) => (await tx.query(
    "select tenant_id, seq, id, at, principal_id, action, subject_type, subject_id, rule_id, details, prev_hash, hash from audit_events order by seq",
  )).rows);
}

test("AUDIT: appendAudit chains hash = sha256Hex(prev_hash + JCS(event))", async () => {
  expect(AUDIT_GENESIS_HASH).toBe("0".repeat(64));
  const ctx = await newTenant();
  await withTenant(fx.app, ctx, async (tx) => {
    await appendAudit(tx, { principalId: ctx.principalId, action: "build.approved", subjectType: "build", subjectId: uuidv7(), details: { approval_id: uuidv7(), brief_hash: sha256Hex("b") } });
    await appendAudit(tx, { principalId: ctx.principalId, action: "policy.decided", subjectType: "routine", subjectId: uuidv7(), ruleId: "builtin.ask_first", details: {} });
  });
  const all = await rows(ctx);
  // tenant.created from createPersonalTenant, then the two above.
  expect(all.map((r) => [Number(r.seq), r.action])).toEqual([[1, "tenant.created"], [2, "build.approved"], [3, "policy.decided"]]);
  let prev = "0".repeat(64);
  for (const r of all) {
    expect(r.prev_hash).toBe(prev);
    const event = {
      tenant_id: r.tenant_id, seq: Number(r.seq), id: r.id, at: (r.at as Date).toISOString(), principal_id: r.principal_id,
      action: r.action, subject_type: r.subject_type, subject_id: r.subject_id, rule_id: r.rule_id, details: r.details, prev_hash: r.prev_hash,
    };
    expect(r.hash).toBe(sha256Hex(prev + jcs(event)));
    expect(r.id).toMatch(/^[0-7][0-9A-HJKMNP-TV-Z]{25}$/);
    prev = r.hash;
  }
  expect(await withTenant(fx.app, ctx, (tx) => verifyAuditChain(tx))).toEqual({ ok: true, checked: 3 });
});

test("AUDIT: two concurrent appends for one tenant produce one chain", async () => {
  const ctx = await newTenant();
  const n = 10;
  await Promise.all(Array.from({ length: n }, (_, i) => withTenant(fx.app, ctx, async (tx) => {
    // Overlap the transactions so they race for the chain head.
    await tx.query("select pg_sleep(0.05)");
    await appendAudit(tx, { principalId: ctx.principalId, action: "batch.committed", subjectType: "batch", subjectId: `b-${i}`, details: { i } });
  })));
  const all = await rows(ctx);
  expect(all.map((r) => Number(r.seq))).toEqual(Array.from({ length: n + 1 }, (_, i) => i + 1));
  expect(new Set(all.map((r) => r.prev_hash)).size).toBe(n + 1);
  for (let i = 1; i < all.length; i++) expect(all[i]!.prev_hash).toBe(all[i - 1]!.hash);
  expect(await withTenant(fx.app, ctx, (tx) => verifyAuditChain(tx))).toEqual({ ok: true, checked: n + 1 });
  // The lock is the per-tenant key from ADR 0018.
  const src = await Bun.file(new URL("../../src/audit.ts", import.meta.url)).text();
  expect(src).toContain("pg_advisory_xact_lock(hashtextextended('audit:' || $1, 0))");
});

test("AUDIT: an audit row rolls back with its transaction", async () => {
  const ctx = await newTenant();
  const subjectId = uuidv7();
  const dispose = onBeforeCommit(() => {
    throw new Error("fault before commit");
  });
  try {
    const err = await fail(withTenant(fx.app, ctx, async (tx) => {
      await tx.query("insert into workspaces (tenant_id, id, name) values ($1, $2, 'w2')", [ctx.tenantId, subjectId]);
      await appendAudit(tx, { principalId: ctx.principalId, action: "workspace.created", subjectType: "workspace", subjectId, details: {} });
    }));
    expect(err?.message).toBe("fault before commit");
  } finally {
    dispose();
  }
  const all = await rows(ctx);
  expect(all.map((r) => r.action)).toEqual(["tenant.created"]);
  const ws = (await fx.admin.query("select count(*)::int as n from workspaces where id = $1", [subjectId])).rows[0].n;
  expect(ws).toBe(0);
  // After the hook is gone, the same write commits and the chain continues from seq 2.
  await withTenant(fx.app, ctx, (tx) => appendAudit(tx, { principalId: ctx.principalId, action: "workspace.created", subjectType: "workspace", subjectId, details: {} }));
  expect((await rows(ctx)).map((r) => Number(r.seq))).toEqual([1, 2]);
});

test("AUDIT: an action not matching the pattern is refused", async () => {
  const ctx = await newTenant();
  for (const action of ["Build.Approved", "build", "build.approved.twice", "build-approved", "build.Approved", ""]) {
    const err = await fail(withTenant(fx.app, ctx, (tx) => appendAudit(tx, { principalId: ctx.principalId, action, details: {} })));
    expect({ action, err: err instanceof AuditEventError }).toEqual({ action, err: true });
  }
  // The database refuses it too, whoever writes.
  const db = await fail(withTenant(fx.app, ctx, (tx) => tx.query(
    `insert into audit_events (tenant_id, seq, id, at, principal_id, action, details, prev_hash, hash)
     values ($1, 99, '01JC0000000000000000000000', now(), 'p', 'Build.Approved', '{}', $2, $2)`, [ctx.tenantId, "a".repeat(64)])));
  expect(db?.message).toMatch(/check constraint/);
  expect((await rows(ctx)).length).toBe(1);
});

test("AUDIT: details with a string longer than 128 characters are refused", async () => {
  const ctx = await newTenant();
  const bad = [
    { note: "x".repeat(129) },
    { nested: { deeper: ["ok", "y".repeat(200)] } },
    { body: "Hello Sam, the invoice is attached" }, // free text, not an id or hash
    { ["k".repeat(129)]: "1" },
  ];
  for (const details of bad) {
    const err = await fail(withTenant(fx.app, ctx, (tx) => appendAudit(tx, { principalId: ctx.principalId, action: "person.read", details })));
    expect(err).toBeInstanceOf(AuditEventError);
  }
  // Exactly 128 characters, ids, hashes, numbers and booleans are fine.
  await withTenant(fx.app, ctx, (tx) => appendAudit(tx, {
    principalId: ctx.principalId, action: "person.read",
    details: { ref: "r".repeat(128), id: uuidv7(), hash: sha256Hex("x"), count: 3, ok: true, none: null, ids: [uuidv7()] },
  }));
  expect((await rows(ctx)).map((r) => r.action)).toEqual(["tenant.created", "person.read"]);
});

test("AUDIT: verifyAuditChain detects edit, delete and fork", async () => {
  const make = async () => {
    const ctx = await newTenant();
    await withTenant(fx.app, ctx, async (tx) => {
      for (let i = 0; i < 3; i++) await appendAudit(tx, { principalId: ctx.principalId, action: "batch.committed", subjectId: `b-${i}`, details: { i } });
    });
    return ctx;
  };
  const tamper = async (sql: string, params: unknown[]) => {
    const c = await fx.admin.connect();
    try {
      await c.query("begin");
      await c.query("alter table audit_events disable trigger append_only_rows");
      await c.query(sql, params);
      await c.query("alter table audit_events enable trigger append_only_rows");
      await c.query("commit");
    } finally {
      c.release();
    }
  };
  const verify = (ctx: TenantContext) => withTenant(fx.app, ctx, (tx) => verifyAuditChain(tx));

  const edited = await make();
  await tamper("update audit_events set details = '{\"i\": 9}' where tenant_id = $1 and seq = 3", [edited.tenantId]);
  expect(await verify(edited)).toEqual({ ok: false, checked: 3, first_bad_seq: 3 });

  const deleted = await make();
  await tamper("delete from audit_events where tenant_id = $1 and seq = 2", [deleted.tenantId]);
  expect(await verify(deleted)).toEqual({ ok: false, checked: 2, first_bad_seq: 3 });

  // Fork: a second row on the same prev_hash is refused by UNIQUE (tenant_id, prev_hash) ...
  const forked = await make();
  const head = (await rows(forked))[1]!;
  const err = await fail(withTenant(fx.app, forked, (tx) => tx.query(
    `insert into audit_events (tenant_id, seq, id, at, principal_id, action, details, prev_hash, hash)
     values ($1, 9, '01JC0000000000000000000009', now(), 'p', 'batch.committed', '{}', $2, $3)`, [forked.tenantId, head.prev_hash, "b".repeat(64)])));
  expect(err?.message).toMatch(/unique|duplicate/);
  // ... and a row re-pointed at another branch is caught by verify.
  await tamper("update audit_events set prev_hash = $2 where tenant_id = $1 and seq = 4", [forked.tenantId, "c".repeat(64)]);
  expect(await verify(forked)).toEqual({ ok: false, checked: 4, first_bad_seq: 4 });

  // An untouched chain still verifies.
  expect(await verify(await make())).toEqual({ ok: true, checked: 4 });
});
