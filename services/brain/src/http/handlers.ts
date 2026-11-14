// Framework-agnostic handlers (web-standard Request -> Response) for the user model routes in docs/API.md:
// GET/PATCH /v1/profile, GET /v1/records/{days,weeks,months,quarters}/{key}, GET /v1/review/week?w=,
// POST /v1/review/answers. services/api mounts them after auth (session or member token) and CSRF.
// Returns null for any other path or method, so the caller can fall through.
import type { RunInTenant } from "../store/tenant.ts";

export interface UserModelAuth {
  tenantId: string;
  memberId: string;
  principalId: string;
  tenantRole: string;
}

export interface HandlerDeps {
  runInTenant: RunInTenant;
  now: () => number;
  /** `req_` + ULID; generated when absent. */
  requestId?: () => string;
}

export async function handleUserModelRequest(_req: Request, _auth: UserModelAuth, _deps: HandlerDeps): Promise<Response | null> {
  throw new Error("not implemented");
}
