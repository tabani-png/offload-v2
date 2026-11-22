import { appendAudit, uuidv7, type Tx } from "@offload/db";

/**
 * Forget scope `import` (docs/API.md "Profile and privacy", SECURITY_PRIVACY.md section 11): the import space is
 * wiped as a unit. Pure SQL on the caller's open transaction (withTenant for the member), so RLS walls every row and a
 * later durable forget (M7) can call it as one step.
 */

export interface ForgetImportInput {
  tenantId: string;
  memberId: string;
  importId: string;
  /** The principal asking (the member), written to purge_requests, purge_log and the audit event. */
  requestedBy: string;
  now: Date;
}

export interface ForgetImportResult {
  purgeRequestId: string;
  rowsDeleted: { observations: number; observation_texts: number; events_outbox: number; imports: number };
}

/**
 * Deletes every row with this import_id: the observations and texts (all partitions), the outbox events that name it
 * and their delivery rows, and the imports row. Writes a done purge request, purge_log and `privacy.forgotten`.
 * Returns null, having changed nothing, when the member has no such import space.
 */
export async function forgetImport(tx: Tx, f: ForgetImportInput): Promise<ForgetImportResult | null> {
  // The row lock serialises with an ingest batch that is about to write into this import space (it reads the row
  // FOR SHARE in its insert transaction).
  const found = await tx.query("select 1 from imports where member_id = $1 and id = $2 for update", [f.memberId, f.importId]);
  if (found.rows.length === 0) return null;

  const eventsOf = "select tenant_id, id from events_outbox where payload->>'member_id' = $1 and payload->>'import_id' = $2";
  await tx.query(`delete from outbox_deliveries where (tenant_id, event_id) in (${eventsOf})`, [f.memberId, f.importId]);
  const events = await tx.query(`delete from events_outbox where (tenant_id, id) in (${eventsOf})`, [f.memberId, f.importId]);
  const obs = await tx.query("delete from observations where member_id = $1 and import_id = $2", [f.memberId, f.importId]);
  const texts = await tx.query("delete from observation_texts where member_id = $1 and import_id = $2", [f.memberId, f.importId]);
  const imports = await tx.query("delete from imports where member_id = $1 and id = $2", [f.memberId, f.importId]);

  const rowsDeleted = {
    observations: obs.rowCount ?? 0, observation_texts: texts.rowCount ?? 0, events_outbox: events.rowCount ?? 0, imports: imports.rowCount ?? 0,
  };
  const purgeRequestId = uuidv7();
  await tx.query(
    `insert into purge_requests (tenant_id, id, member_id, scope, scope_ref, state, requested_by, created_at, finished_at)
     values ($1, $2, $3, 'import', $4, 'done', $5, $6, $6)`,
    [f.tenantId, purgeRequestId, f.memberId, f.importId, f.requestedBy, f.now],
  );
  await tx.query(
    `insert into purge_log (tenant_id, id, purge_request_id, scope, scope_ref, rows_deleted, requested_by, at)
     values ($1, $2, $3, 'import', $4, $5, $6, $7)`,
    [f.tenantId, uuidv7(), purgeRequestId, f.importId, JSON.stringify(rowsDeleted), f.requestedBy, f.now],
  );
  await appendAudit(tx, {
    principalId: f.requestedBy, action: "privacy.forgotten", subjectType: "purge_request", subjectId: purgeRequestId,
    details: { scope: "import", import_id: f.importId, purge_request_id: purgeRequestId },
  });
  return { purgeRequestId, rowsDeleted };
}
