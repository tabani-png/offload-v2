import { sha256Hex } from "@offload/contracts";
import { appendAudit } from "./audit.ts";
import { uuidv7 } from "./ids.ts";
import type { Tx } from "./tenancy.ts";

export type MemberRole = "owner" | "admin" | "member" | "auditor";
export type MemberState = "invited" | "active" | "leaving" | "frozen" | "departed";
const ROLES: readonly MemberRole[] = ["owner", "admin", "member", "auditor"];
const STATES: readonly MemberState[] = ["invited", "active", "leaving", "frozen", "departed"];

export class LastOwnerError extends Error {
  readonly code = "last_owner";
  constructor() {
    super("this change would leave the tenant with no active owner");
    this.name = "LastOwnerError";
  }
}

export interface PersonalTenant {
  tenantId: string;
  workspaceId: string;
  memberId: string;
}

/** email_hash = sha256Hex(lowercase(trim(email))), DATA_MODEL.md section 1. */
export function emailHash(email: string): string {
  return sha256Hex(email.trim().toLowerCase());
}

/**
 * Sign-up: a personal tenant with one workspace and one active owner, audited as tenant.created. Runs in a
 * transaction with no tenant yet (withTransaction); sets app.tenant_id to the new id before inserting (tenants RLS).
 */
export async function createPersonalTenant(tx: Tx, input: { idpSubject: string; email: string }): Promise<PersonalTenant> {
  const email = input.email.trim();
  if (!email.includes("@")) throw new TypeError("createPersonalTenant: email is required");
  if (!input.idpSubject) throw new TypeError("createPersonalTenant: idpSubject is required");
  const tenantId = uuidv7();
  const workspaceId = uuidv7();
  const memberId = uuidv7();
  await tx.query(
    `select set_config('app.tenant_id', $1, true), set_config('app.member_id', $2, true),
            set_config('app.principal_id', $2, true), set_config('app.tenant_role', 'owner', true),
            set_config('app.member_scope', 'member', true)`,
    [tenantId, memberId],
  );
  await tx.query("insert into tenants (id, kind, name) values ($1, 'personal', 'Personal')", [tenantId]);
  await tx.query("insert into workspaces (tenant_id, id, name) values ($1, $2, 'Personal')", [tenantId, workspaceId]);
  await tx.query(
    `insert into members (tenant_id, id, email, email_hash, tenant_role, state, idp_subject)
     values ($1, $2, $3, $4, 'owner', 'active', $5)`,
    [tenantId, memberId, email, emailHash(email), input.idpSubject],
  );
  await tx.query(
    "insert into workspace_members (tenant_id, workspace_id, member_id, workspace_role) values ($1, $2, $3, 'lead')",
    [tenantId, workspaceId, memberId],
  );
  await appendAudit(tx, {
    principalId: memberId, action: "tenant.created", subjectType: "tenant", subjectId: tenantId,
    details: { workspace_id: workspaceId, member_id: memberId },
  });
  return { tenantId, workspaceId, memberId };
}

async function principal(tx: Tx): Promise<string> {
  const p = (await tx.query<{ p: string | null }>("select nullif(current_setting('app.principal_id', true), '') as p")).rows[0]?.p;
  if (!p) throw new Error("no principal: run inside withTenant");
  return p;
}

/** Locks the tenant's owner rows and the target, then refuses a change that leaves no active owner. */
async function guardLastOwner(tx: Tx, memberId: string, stillOwner: (cur: { tenant_role: string; state: string }) => boolean) {
  const rows = (await tx.query<{ id: string; tenant_role: string; state: string }>(
    `select id, tenant_role, state from members
     where tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid and (tenant_role = 'owner' or id = $1)
     order by id for update`,
    [memberId],
  )).rows;
  const target = rows.find((r) => r.id === memberId);
  if (!target) throw new Error("member not found");
  const activeOwners = rows.filter((r) => r.tenant_role === "owner" && r.state === "active");
  const targetIsActiveOwner = target.tenant_role === "owner" && target.state === "active";
  if (targetIsActiveOwner && !stillOwner(target) && activeOwners.length <= 1) throw new LastOwnerError();
  return target;
}

export async function setMemberRole(tx: Tx, memberId: string, role: MemberRole): Promise<void> {
  if (!ROLES.includes(role)) throw new TypeError("setMemberRole: unknown role");
  const target = await guardLastOwner(tx, memberId, () => role === "owner");
  if (target.tenant_role === role) return;
  await tx.query("update members set tenant_role = $2 where id = $1", [memberId, role]);
  await appendAudit(tx, { principalId: await principal(tx), action: "member.role_changed", subjectType: "member", subjectId: memberId, details: { from: target.tenant_role, to: role } });
}

export async function setMemberState(tx: Tx, memberId: string, state: MemberState): Promise<void> {
  if (!STATES.includes(state)) throw new TypeError("setMemberState: unknown state");
  const target = await guardLastOwner(tx, memberId, () => state === "active");
  if (target.state === state) return;
  await tx.query("update members set state = $2 where id = $1", [memberId, state]);
  await appendAudit(tx, { principalId: await principal(tx), action: "member.state_changed", subjectType: "member", subjectId: memberId, details: { from: target.state, to: state } });
}
