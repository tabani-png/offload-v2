// ApprovalPort: the one approval scheme of ADR 0004 as the builder needs it, until packages/policy and the approvals
// table land (m2-06). Exact hashes, single use, 24 h TTL, an internal 32-byte token of which only sha256 is kept.
// The token never leaves the server: the OK handler hands it to the build workflow in process; it is never stored,
// logged or returned. Attempt claims (one per worker, s35's "each builder its own approval claim") are minted only
// from a claimed build approval, by policy rule `core.build.attempt`, and bind the same hashes plus the ordinal.
import { randomBytes, timingSafeEqual } from "node:crypto";
import { sha256Hex } from "./hash.ts";

export const APPROVAL_TTL_MS = 24 * 3_600_000;
export type ApprovalKind = "build" | "deploy" | "batch" | "graduation";
export type ApprovalCode = "hash_mismatch" | "approval_used" | "approval_expired" | "not_found" | "forbidden";

export class ApprovalError extends Error {
  constructor(readonly code: ApprovalCode, message: string) {
    super(message);
  }
}

export interface Approval {
  id: string;
  tenant_id: string;
  kind: ApprovalKind;
  subject_id: string;
  bound_hashes: Record<string, string>;
  token_sha256: string;
  approver_kind: "person" | "policy";
  approver_member_id: string | null;
  rule_id: string | null;
  parent_approval_id: string | null;
  created_at: number;
  expires_at: number;
  claimed_at: number | null;
  released_at: number | null;
}

export interface MintInput {
  tenant_id: string;
  kind: ApprovalKind;
  subject_id: string;
  bound: Record<string, string>;
  approver_kind: "person" | "policy";
  approver_member_id?: string | null;
  rule_id?: string | null;
  /** For a policy claim derived from a person's approval: the parent must be claimed, unexpired, and bound the same. */
  parent_approval_id?: string;
}

export interface ApprovalPort {
  mint(i: MintInput, now: number): Promise<{ approval_id: string; token: string }>;
  /** Atomically claims the approval once (twice when released once); every bound hash must equal. */
  claim(i: { tenant_id: string; approval_id: string; token: string; bound: Record<string, string> }, now: number): Promise<Approval>;
  /** Releases a claimed approval once (ADR 0031: an infra_failed build with no model spend). */
  release(i: { tenant_id: string; approval_id: string }, now: number): Promise<void>;
  get(tenant_id: string, approval_id: string): Promise<Approval | null>;
}

const sameBound = (want: Record<string, string>, got: Record<string, string>) => {
  const a = Object.keys(want).sort();
  const b = Object.keys(got).sort();
  return a.length === b.length && a.every((k, i) => k === b[i] && want[k] === got[k]);
};

/** In-memory adapter. Every check and write happens synchronously after the last await, so it is atomic in one process. */
export class MemoryApprovals implements ApprovalPort {
  readonly rows = new Map<string, Approval>();
  private readonly claims = new Map<string, number>();

  async mint(i: MintInput, now: number): Promise<{ approval_id: string; token: string }> {
    if (i.parent_approval_id !== undefined) {
      const p = this.rows.get(i.parent_approval_id);
      if (p === undefined || p.tenant_id !== i.tenant_id) throw new ApprovalError("forbidden", "no parent approval");
      if (p.claimed_at === null) throw new ApprovalError("forbidden", "the parent approval is not claimed");
      if (now > p.expires_at) throw new ApprovalError("approval_expired", "the parent approval expired");
      for (const [k, v] of Object.entries(p.bound_hashes)) if (i.bound[k] !== v) throw new ApprovalError("hash_mismatch", "a derived approval must bind its parent's hashes");
    }
    const token = randomBytes(32).toString("base64url");
    const id = crypto.randomUUID();
    this.rows.set(id, {
      id,
      tenant_id: i.tenant_id,
      kind: i.kind,
      subject_id: i.subject_id,
      bound_hashes: { ...i.bound },
      token_sha256: sha256Hex(token),
      approver_kind: i.approver_kind,
      approver_member_id: i.approver_member_id ?? null,
      rule_id: i.rule_id ?? null,
      parent_approval_id: i.parent_approval_id ?? null,
      created_at: now,
      expires_at: now + APPROVAL_TTL_MS,
      claimed_at: null,
      released_at: null,
    });
    return { approval_id: id, token };
  }

  async claim(i: { tenant_id: string; approval_id: string; token: string; bound: Record<string, string> }, now: number): Promise<Approval> {
    const a = this.rows.get(i.approval_id);
    if (a === undefined || a.tenant_id !== i.tenant_id) throw new ApprovalError("not_found", "no such approval");
    const want = Buffer.from(a.token_sha256, "hex");
    const got = Buffer.from(sha256Hex(typeof i.token === "string" ? i.token : ""), "hex");
    if (want.length !== got.length || !timingSafeEqual(want, got)) throw new ApprovalError("forbidden", "wrong approval token");
    if (now > a.expires_at) throw new ApprovalError("approval_expired", "the approval is older than 24 hours");
    if (!sameBound(a.bound_hashes, i.bound)) throw new ApprovalError("hash_mismatch", "the approval is for other hashes");
    const used = this.claims.get(a.id) ?? 0;
    if (used >= (a.released_at === null ? 1 : 2)) throw new ApprovalError("approval_used", "the approval was already used");
    this.claims.set(a.id, used + 1);
    if (a.claimed_at === null) a.claimed_at = now;
    return { ...a };
  }

  async release(i: { tenant_id: string; approval_id: string }, now: number): Promise<void> {
    const a = this.rows.get(i.approval_id);
    if (a === undefined || a.tenant_id !== i.tenant_id) throw new ApprovalError("not_found", "no such approval");
    if (a.claimed_at === null) throw new ApprovalError("forbidden", "only a claimed approval can be released");
    if (a.released_at !== null) throw new ApprovalError("approval_used", "the approval was already released once");
    a.released_at = now;
  }

  async get(tenant_id: string, approval_id: string): Promise<Approval | null> {
    const a = this.rows.get(approval_id);
    return a === undefined || a.tenant_id !== tenant_id ? null : { ...a };
  }
}
