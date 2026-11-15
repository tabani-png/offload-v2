import { jcs } from "@offload/contracts";
import type { Tx } from "../tenancy.ts";
import type { ServiceSigner } from "./signer.ts";

/** The bytes an anchor signs: JCS of these four fields (ADR 0018). `signed_at` is RFC 3339 UTC with milliseconds. */
export function anchorBytes(a: { tenant_id: string; seq: number; head_hash: string; signed_at: string }): Uint8Array {
  return new TextEncoder().encode(jcs({ tenant_id: a.tenant_id, seq: a.seq, head_hash: a.head_hash, signed_at: a.signed_at }));
}

export interface AnchorRow {
  seq: number;
  head_hash: string;
  signed_at: string;
  key_id: string;
}

/**
 * Signs the chain head of `tenantId` and stores it, in the caller's transaction (run it inside withTenant; no network
 * I/O). Returns null and writes nothing when the newest anchor already covers the head, or the chain is empty.
 */
export async function writeAnchor(tx: Tx, tenantId: string, signer: ServiceSigner, now: Date): Promise<AnchorRow | null> {
  const head = (await tx.query<{ seq: string; hash: string }>(
    "select seq, hash from audit_events where tenant_id = $1 order by seq desc limit 1", [tenantId],
  )).rows[0];
  if (!head) return null;
  const seq = Number(head.seq);
  const last = (await tx.query<{ seq: string }>(
    "select seq from audit_anchors where tenant_id = $1 order by seq desc limit 1", [tenantId],
  )).rows[0];
  if (last && Number(last.seq) >= seq) return null;
  const signedAt = now.toISOString();
  const signature = Buffer.from(signer.sign(anchorBytes({ tenant_id: tenantId, seq, head_hash: head.hash, signed_at: signedAt }))).toString("base64url");
  // Two jobs racing for one tenant: the second insert loses on the primary key and writes nothing.
  const ins = await tx.query(
    `insert into audit_anchors (tenant_id, seq, head_hash, signed_at, signature, key_id, sink_ref)
     values ($1, $2, $3, $4, $5, $6, null) on conflict do nothing`,
    [tenantId, seq, head.hash, signedAt, signature, signer.keyId],
  );
  return ins.rowCount === 1 ? { seq, head_hash: head.hash, signed_at: signedAt, key_id: signer.keyId } : null;
}
