# 0017. Policy engine: Cedar

Status: accepted · Date: 2026-11-14

## Context
Offload must decide, deterministically and explainably, who may approve what, which routines may commit without
asking, which capabilities a workspace may use, and spend limits. Enterprise customers want to write their own rules.

## Decision
- Use **Cedar** (Apache-2.0) through `@cedar-policy/cedar-wasm` (Apache-2.0) in `packages/policy`, behind a
  `PolicyEngine` port: `decide(principal, action, resource, context) → { decision: 'allow'|'ask'|'deny', rule_id, reasons }`.
- Cedar returns allow or deny. Offload's three-way decision comes from two policy sets: `deny` set → `deny`;
  `auto` set allows → `allow`; else `ask` set allows → `ask`; else `deny`. Default deny.
- **Core ships built-in policies** (read-only, versioned in `packages/policy/policies/`):
  - only `owner` and `admin` may change tenant settings; `auditor` reads audit and aggregates only;
  - build and deploy approvals: the member who owns the opportunity, or a workspace `lead`, or `admin`/`owner`;
  - commits ask unless the routine is in `auto_commit` and within its limits;
  - no commits between 01:00 and 03:59 in the member's local time;
  - browser-automation commits always ask;
  - per-run and per-day commit limits from the routine's policy;
  - the build cap ($4.00) and the tenant's monthly model budget.
- **EE adds** (`ee/packages/governance`): custom Cedar policies per tenant, multi-step approval chains (N of M
  approvers), policy simulation against past runs, policy versioning with approval.
- Every decision records `rule_id` in the audit event, so "why was this allowed" has an answer.
- Policies are evaluated in the API and runtime processes; the policy store is a table `policies` (tenant-owned, RLS).

## Consequences
- The WASM module is about a few MB and must load in Bun; checked in the first policy slice (M5).
- The 2026 advisory on Cedar JSON template slot-id validation must be checked against the pinned version before use.

## Alternatives considered
- OPA/Rego: Apache-2.0, mature, but a separate server or WASM build and a less readable language for admins.
- Hand-written TypeScript rules: fine for core but no path to customer-written policies.
- Casbin: weaker typing and analysis.

## Sources
cedar-policy/cedar (Apache-2.0); research Page (Cortexa Paladin: rule id on every decision); old ADR 0102, 0106.
