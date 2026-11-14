// RoutinePort: the runtime's side of the deploy approval (m2-09, services/runtime): creates the routine version from
// the approved artifact and definition. The builder calls it once, after the deploy approval is claimed.
export interface RoutinePort {
  deploy(i: { tenant_id: string; member_id: string; build_id: string; artifact_sha256: string; definition_hash: string; receipt_hash: string }): Promise<{ routine_id: string; version: number }>;
}
