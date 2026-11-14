// GATE (ADR 0004, SECURITY_PRIVACY section 13): one approval scheme. Exact hashes, single use, 24 h TTL, only
// sha256(token) at rest. Old approval.ts had no TTL, bound two hashes, and was minted by the loop itself.
import { describe, expect, test } from "bun:test";
import { APPROVAL_TTL_MS, ApprovalError, MemoryApprovals } from "../../src/approvals.ts";
import { sha256Hex } from "../../src/hash.ts";
import { MEMBER, T0, TENANT } from "./setup.ts";

const BOUND = { brief_hash: "a".repeat(64), check_set_hash: "b".repeat(64), held_out_hash: "c".repeat(64), fixture_set_hash: "d".repeat(64), cap_usd: "4.0000" };
const mintBuild = (a: MemoryApprovals, now = T0) =>
  a.mint({ tenant_id: TENANT, kind: "build", subject_id: "build-1", bound: BOUND, approver_kind: "person", approver_member_id: MEMBER }, now);
const codeOf = async (p: Promise<unknown>) => {
  try {
    await p;
    return "ok";
  } catch (e) {
    return e instanceof ApprovalError ? e.code : `other: ${String(e)}`;
  }
};

describe("p45a approvals", () => {
  test("GATE: an approval binds exact hashes; a claim with any other hash is hash_mismatch and leaves it unclaimed", async () => {
    const a = new MemoryApprovals();
    const { approval_id, token } = await mintBuild(a);
    for (const k of Object.keys(BOUND)) {
      const bad = { ...BOUND, [k]: k === "cap_usd" ? "4.0001" : "e".repeat(64) };
      expect(await codeOf(a.claim({ tenant_id: TENANT, approval_id, token, bound: bad }, T0 + 1))).toBe("hash_mismatch");
    }
    expect((await a.get(TENANT, approval_id))!.claimed_at).toBeNull();
    expect(await codeOf(a.claim({ tenant_id: TENANT, approval_id, token, bound: BOUND }, T0 + 1))).toBe("ok");
  });

  test("GATE: a claim names the approval's kind and subject; another kind or subject is refused", async () => {
    const a = new MemoryApprovals();
    const { approval_id, token } = await mintBuild(a);
    expect(await codeOf(a.claim({ tenant_id: TENANT, approval_id, token, bound: BOUND, kind: "deploy", subject_id: "build-1" }, T0 + 1))).toBe("forbidden");
    expect(await codeOf(a.claim({ tenant_id: TENANT, approval_id, token, bound: BOUND, kind: "build", subject_id: "build-2" }, T0 + 1))).toBe("forbidden");
    expect(await codeOf(a.claim({ tenant_id: TENANT, approval_id, token, bound: BOUND, kind: "build", subject_id: "build-1" }, T0 + 1))).toBe("ok");
  });

  test("GATE: a claimed approval cannot be claimed again (approval_used)", async () => {
    const a = new MemoryApprovals();
    const { approval_id, token } = await mintBuild(a);
    const both = await Promise.all([1, 2].map(() => codeOf(a.claim({ tenant_id: TENANT, approval_id, token, bound: BOUND }, T0 + 1))));
    expect(both.sort()).toEqual(["approval_used", "ok"]);
  });

  test("GATE: an approval older than 24 h is approval_expired", async () => {
    const a = new MemoryApprovals();
    const { approval_id, token } = await mintBuild(a);
    expect(APPROVAL_TTL_MS).toBe(24 * 3_600_000);
    expect(await codeOf(a.claim({ tenant_id: TENANT, approval_id, token, bound: BOUND }, T0 + APPROVAL_TTL_MS + 1))).toBe("approval_expired");
    const b = await mintBuild(a);
    expect(await codeOf(a.claim({ tenant_id: TENANT, approval_id: b.approval_id, token: b.token, bound: BOUND }, T0 + APPROVAL_TTL_MS))).toBe("ok");
  });

  test("GATE: only sha256 of the token is stored; a wrong token or another tenant is refused", async () => {
    const a = new MemoryApprovals();
    const { approval_id, token } = await mintBuild(a);
    expect(Buffer.from(token, "base64url").length).toBe(32);
    const row = (await a.get(TENANT, approval_id))!;
    expect(row.token_sha256).toBe(sha256Hex(token));
    expect(JSON.stringify(row)).not.toContain(token);
    expect(row.expires_at - row.created_at).toBe(APPROVAL_TTL_MS);
    expect(await codeOf(a.claim({ tenant_id: TENANT, approval_id, token: token.slice(0, -2) + "AA", bound: BOUND }, T0 + 1))).toBe("forbidden");
    expect(await codeOf(a.claim({ tenant_id: "0193a6f2-0000-7000-8000-000000000009", approval_id, token, bound: BOUND }, T0 + 1))).toBe("not_found");
    expect((await a.get(TENANT, approval_id))!.claimed_at).toBeNull();
  });

  test("GATE: an attempt claim can be minted only from a claimed build approval, and each is single-use", async () => {
    const a = new MemoryApprovals();
    const parent = await mintBuild(a);
    const attempt = (n: number) =>
      a.mint({ tenant_id: TENANT, kind: "build", subject_id: `attempt-${n}`, bound: { ...BOUND, attempt_ordinal: String(n) }, approver_kind: "policy", rule_id: "core.build.attempt", parent_approval_id: parent.approval_id }, T0 + 2);
    expect(await codeOf(attempt(1))).toBe("forbidden");
    await a.claim({ tenant_id: TENANT, approval_id: parent.approval_id, token: parent.token, bound: BOUND }, T0 + 1);
    const one = await attempt(1);
    const two = await attempt(2);
    expect(one.approval_id).not.toBe(two.approval_id);
    const claim = (x: { approval_id: string; token: string }, n: number) => a.claim({ tenant_id: TENANT, approval_id: x.approval_id, token: x.token, bound: { ...BOUND, attempt_ordinal: String(n) } }, T0 + 3);
    expect(await codeOf(claim(one, 1))).toBe("ok");
    expect(await codeOf(claim(one, 1))).toBe("approval_used");
    expect(await codeOf(claim(two, 1))).toBe("hash_mismatch");
    expect(await codeOf(claim(two, 2))).toBe("ok");
    // a parent bound hash cannot be changed in the child
    expect(await codeOf(a.mint({ tenant_id: TENANT, kind: "build", subject_id: "attempt-3", bound: { ...BOUND, check_set_hash: "f".repeat(64) }, approver_kind: "policy", rule_id: "core.build.attempt", parent_approval_id: parent.approval_id }, T0 + 2))).toBe("hash_mismatch");
  });

  test("GATE: a released approval can be claimed exactly once more, and released only once", async () => {
    const a = new MemoryApprovals();
    const { approval_id, token } = await mintBuild(a);
    const claim = () => codeOf(a.claim({ tenant_id: TENANT, approval_id, token, bound: BOUND }, T0 + 5));
    expect(await codeOf(a.release({ tenant_id: TENANT, approval_id }, T0 + 1))).toBe("forbidden");
    expect(await claim()).toBe("ok");
    expect(await codeOf(a.release({ tenant_id: TENANT, approval_id }, T0 + 6))).toBe("ok");
    expect(await codeOf(a.release({ tenant_id: TENANT, approval_id }, T0 + 7))).toBe("approval_used");
    expect(await claim()).toBe("ok");
    expect(await claim()).toBe("approval_used");
  });
});
