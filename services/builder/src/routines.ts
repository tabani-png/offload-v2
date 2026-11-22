// RoutinePort: the runtime's side of the deploy approval (m2-09, services/runtime): creates the routine version from
// the approved artifact and definition. The builder calls it once, after the deploy approval is claimed.
export interface RoutinePort {
  /** `idempotency_key` is `deploy:<build_id>`, the same on every retry. m2-09 must honour it: a second call with the
   * same key returns the routine version the first one created (a timeout after creation must not make a second). */
  deploy(i: { tenant_id: string; member_id: string; build_id: string; artifact_sha256: string; definition_hash: string; receipt_hash: string; idempotency_key: string }): Promise<{ routine_id: string; version: number }>;
}
