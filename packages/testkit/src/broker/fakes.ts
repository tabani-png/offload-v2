import type { ApprovalVerdict, ApprovalVerifier, RunScopeSource } from "@offload/contracts/src/broker/index.ts";

/** fakeRunScope(): RunScopeSource over in-memory maps; records every lookup. */
export interface FakeRunScope extends RunScopeSource {
  runs: Map<string, string[]>;
  fixtureSets: Map<string, string[]>;
  lookups: string[];
}

export function fakeRunScope(init: { runs?: Record<string, string[]>; fixtureSets?: Record<string, string[]> } = {}): FakeRunScope {
  const runs = new Map(Object.entries(init.runs ?? {}));
  const fixtureSets = new Map(Object.entries(init.fixtureSets ?? {}));
  const lookups: string[] = [];
  return {
    runs,
    fixtureSets,
    lookups,
    async readSet(_tenantId, runId) {
      lookups.push(`run:${runId}`);
      return runs.get(runId) ?? null;
    },
    async fixtureScope(_tenantId, fixtureSetId) {
      lookups.push(`fixture:${fixtureSetId}`);
      return fixtureSets.get(fixtureSetId) ?? null;
    },
  };
}

export interface FakeApprovals extends ApprovalVerifier {
  /** approval id -> item hashes the approved batch holds. */
  approved: Map<string, Set<string>>;
  /** approval id -> terminal state other than ok. */
  state: Map<string, "approval_used" | "approval_expired">;
  checks: { approvalId: string; itemHash: string }[];
}

export function fakeApprovals(): FakeApprovals {
  const approved = new Map<string, Set<string>>();
  const state = new Map<string, "approval_used" | "approval_expired">();
  const checks: { approvalId: string; itemHash: string }[] = [];
  return {
    approved,
    state,
    checks,
    async check(_tenantId, approvalId, itemHash): Promise<ApprovalVerdict> {
      checks.push({ approvalId, itemHash });
      const terminal = state.get(approvalId);
      if (terminal) return terminal;
      const hashes = approved.get(approvalId);
      if (!hashes) return "forbidden";
      return hashes.has(itemHash) ? "ok" : "hash_mismatch";
    },
  };
}
