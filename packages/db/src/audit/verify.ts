import type { AuditVerifyResult } from "@offload/contracts";
import { AUDIT_GENESIS_HASH, auditHash, type AuditEvent } from "../audit.ts";
import type { Tx } from "../tenancy.ts";
import { anchorBytes } from "./anchor.ts";
import type { ServiceSigner } from "./signer.ts";

/**
 * Walks the tenant's chain from seq 1, then checks every anchor. An edited event is `hash_mismatch`, a deleted one
 * `seq_gap`, a row on another branch (a fork) `prev_hash_mismatch` at the later row. `first_bad_seq` is the lowest
 * failing seq over the chain and the anchors; `checked` is the number of events walked.
 */
export async function verifyChain(tx: Tx, tenantId: string, signer: ServiceSigner): Promise<AuditVerifyResult> {
  const rows = (await tx.query(
    `select tenant_id, seq, id, at, principal_id, action, subject_type, subject_id, rule_id, details, prev_hash, hash
     from audit_events where tenant_id = $1 order by seq`, [tenantId],
  )).rows;
  let bad: { seq: number; reason: NonNullable<AuditVerifyResult["reason"]> } | null = null;
  const hashAt = new Map<number, string>();
  let prev = AUDIT_GENESIS_HASH;
  let expectedSeq = 1;
  for (const r of rows) {
    const seq = Number(r.seq);
    hashAt.set(seq, r.hash);
    if (bad) {
      expectedSeq = seq + 1;
      prev = r.hash;
      continue;
    }
    const event: AuditEvent = {
      tenant_id: r.tenant_id, seq, id: r.id, at: (r.at as Date).toISOString(), principal_id: r.principal_id,
      action: r.action, subject_type: r.subject_type, subject_id: r.subject_id, rule_id: r.rule_id, details: r.details,
      prev_hash: r.prev_hash,
    };
    if (seq !== expectedSeq) bad = { seq, reason: "seq_gap" };
    else if (r.prev_hash !== prev) bad = { seq, reason: "prev_hash_mismatch" };
    else if (auditHash(event) !== r.hash) bad = { seq, reason: "hash_mismatch" };
    expectedSeq = seq + 1;
    prev = r.hash;
  }
  const anchors = (await tx.query(
    "select seq, head_hash, signed_at, signature, key_id from audit_anchors where tenant_id = $1 order by seq", [tenantId],
  )).rows;
  for (const a of anchors) {
    const seq = Number(a.seq);
    if (bad && bad.seq <= seq) break;
    let reason: NonNullable<AuditVerifyResult["reason"]> | null = null;
    if (hashAt.get(seq) !== a.head_hash) reason = "anchor_mismatch";
    else {
      const bytes = anchorBytes({ tenant_id: tenantId, seq, head_hash: a.head_hash, signed_at: (a.signed_at as Date).toISOString() });
      let ok = false;
      try {
        ok = signer.verify(bytes, new Uint8Array(Buffer.from(a.signature, "base64url")), a.key_id);
      } catch {
        ok = false;
      }
      if (!ok) reason = "anchor_signature";
    }
    if (reason) {
      bad = { seq, reason };
      break;
    }
  }
  return bad ? { ok: false, checked: rows.length, first_bad_seq: bad.seq, reason: bad.reason } : { ok: true, checked: rows.length };
}
