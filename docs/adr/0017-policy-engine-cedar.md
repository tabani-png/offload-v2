# 0017. Policy engine: TypeScript rules first, Cedar for custom policies

Status: accepted, revised 2026-11-14 · Date: 2026-11-14

## Context
Offload must decide, deterministically and explainably, who may approve what, which routines may commit without
asking, which capabilities a workspace may use, and spend limits. Enterprise customers want to write their own rules.
The first milestones need about seven fixed rules; Cedar on Bun through WASM is a second unverified dependency on the
critical path ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(6)).

## Decision
- A **`PolicyEngine` port** in `packages/policy`:
  `decide(principal, action, resource, context) → { decision: 'allow'|'ask'|'deny', rule_id, reasons }`. Default deny.
- **Core ships hand-written TypeScript rules** behind the port, each with a stable `rule_id`, versioned in
  `packages/policy/src/rules/`:
  - `core.tenant.settings`: only `owner` and `admin` change tenant settings; `auditor` reads audit and aggregates only;
  - `core.approve.build_deploy`: build and deploy approvals by the member who owns the opportunity, a workspace
    `lead`, or `admin`/`owner`;
  - `core.commit.ask`: commits ask unless the routine is in `auto_commit` and within its limits;
  - `core.commit.quiet_hours`: no commits inside the routine's quiet hours. Default 01:00 to 03:59 member-local,
    set per routine in `routine.json` `limits.quiet_hours` (a nightly routine may set none);
  - `core.commit.browser_ask`: browser-automation commits always ask;
  - `core.commit.limits`: per-run and per-day commit limits from the routine;
  - `core.budget`: the build cap ($4.00) and the tenant's monthly model budget.
- **Cedar** (Apache-2.0, `@cedar-policy/cedar-wasm`) arrives with **EE custom policies in M9** (`ee/packages/governance`):
  custom policies per tenant, approval chains (N of M), policy simulation against past runs, policy versioning with
  approval. Cedar returns allow or deny; the three-way decision comes from three policy sets: `deny` → deny; `auto`
  allows → allow; else `ask` allows → ask; else deny. The built-in TS rules run first and cannot be overridden to
  weaken safety rules.
- Every decision records `rule_id` in the audit event, so "why was this allowed" has an answer (a pattern from the
  research Page).
- Policies are evaluated in-process; custom policies are stored in `policies` (tenant-owned, RLS).
- Patterns borrowed from cortexa.network (operations graph, governed flows), patterns only, no code: routines are
  modelled as governed flows whose every edge (approve, commit, graduate) passes the engine.

## Consequences
- M2 needs no WASM dependency. The Cedar WASM module must load in Bun; checked in M9, along with the 2026 advisory on
  Cedar JSON template slot-id validation against the pinned version.

## Alternatives considered
- Cedar from the start (the previous version): off the critical path now ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(6)).
- OPA/Rego: Apache-2.0, mature, but a separate server or WASM build and a less readable language for admins.
- Casbin: weaker typing and analysis.

## Sources
cedar-policy/cedar (Apache-2.0); research Page ("rule id on every decision"); cortexa.network (repo-scout log, patterns
only); old ADR 0102, 0105 (quiet window), 0106.

## Revisions
- 2026-11-14: TypeScript rules first, Cedar only with EE custom policies in M9 ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(6)); quiet hours are a
  per-routine default ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P2); Cortexa reference is cortexa.network, rule id attributed to the research Page
  ([design review B (2026-11-14)](../SOURCES.md#design-review-b), 7).
