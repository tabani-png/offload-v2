// FixStore: what the fix designer froze before OK, build (m2-05, services/brain). The builder reads it by fix id and
// re-checks every hash against the approval before it uses anything.
import type { Brief, CheckSet } from "./checks.ts";
import type { SandboxFile } from "./sandbox/provider.ts";

export interface FrozenFix {
  fix_id: string;
  brief_id: string;
  brief: Brief;
  brief_hash: string;
  check_set: CheckSet;
  /** Never readable by workers: it goes only into fresh verification sandboxes. */
  held_out: CheckSet;
  fixture_set_hash: string;
  /** Tokenised fixtures (ADR 0027): `tok_` stand-ins only; the token map never enters a sandbox. */
  fixtures: SandboxFile[];
}

export interface FixStore {
  frozen(tenant_id: string, fix_id: string): Promise<FrozenFix | null>;
}
