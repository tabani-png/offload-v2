// BuildStore: builds, worker attempts, budget reservations and budget entries (DATA_MODEL section 6, section 8).
// The build lock is "one live build per brief": a partial unique index in Postgres (store-pg.ts), the same rule here.
// A live build whose heartbeat is older than the stale limit was left by a dead orchestrator; the next OK ends it
// infra_failed and takes its place (old s35 stale ok-build.lock recovery, ADR 0031). Money is integer USD × 10_000.

export type BuildState = "queued" | "building" | "verifying" | "fanning_out" | "repairing" | "ready" | "failed" | "capped" | "tampered" | "cancelled" | "infra_failed";
export const LIVE_STATES: readonly BuildState[] = ["queued", "building", "verifying", "fanning_out", "repairing"];
export const isLive = (s: BuildState) => LIVE_STATES.includes(s);

export interface Stage {
  name: string;
  state: "running" | "done" | "failed";
  started_at: number;
  ended_at: number | null;
  /** Fixed plain words chosen by code: never exception text, paths, tokens or held-out output. */
  note: string | null;
}

export interface NewBuild {
  tenant_id: string;
  id: string;
  fix_id: string;
  brief_id: string;
  cap_usd4: number;
  fanout_workers: number;
  /** The hashes and cap the OK, build approval binds. */
  bound_hashes: Record<string, string>;
}

export interface BuildRow extends NewBuild {
  approval_id: string | null;
  state: BuildState;
  spent_usd4: number;
  infra_retries: number;
  stages: Stage[];
  winner_attempt_id: string | null;
  artifact_sha256: string | null;
  receipt_hash: string | null;
  definition_hash: string | null;
  receipt: unknown;
  created_at: number;
  heartbeat_at: number;
  started_at: number | null;
  ended_at: number | null;
  deployed_at: number | null;
}

export type BuildPatch = Partial<Pick<BuildRow, "approval_id" | "state" | "stages" | "winner_attempt_id" | "artifact_sha256" | "receipt_hash" | "definition_hash" | "receipt" | "started_at" | "ended_at" | "infra_retries">>;

export interface CheckGroup {
  name: string;
  passed: number;
  failed: number;
}

export interface AttemptRow {
  tenant_id: string;
  id: string;
  build_id: string;
  ordinal: number;
  sandbox_provider: string;
  sandbox_id: string | null;
  /** `running` from the moment the worker starts: its held-out check counts as used from then on. */
  outcome: "running" | "pass" | "fail" | "cap" | "tamper" | "error";
  spent_usd4: number;
  tries: number;
  turns: number;
  frozen_pass: boolean | null;
  held_out_pass: boolean | null;
  check_groups: CheckGroup[];
  artifact_sha256: string | null;
  artifact_bytes: number;
  artifact_files: string[];
  note: string;
}

export interface Reservation {
  tenant_id: string;
  build_id: string;
  attempt_id: string;
  call_id: string;
  kind: "model" | "sandbox";
  usd4: number;
  /** The most the build may have settled plus reserved after this one: cap minus the checks reserve. */
  ceiling_usd4: number;
}

export interface Settlement {
  tenant_id: string;
  build_id: string;
  call_id: string;
  idempotency_key: string;
  /** `infra` spend is recorded and never counts toward the build cap (ADR 0031). */
  scope: "build" | "infra";
  usd4: number;
  model?: string | null;
  sandbox_seconds?: number | null;
}

export class BuildConflict extends Error {
  constructor(readonly code: "already_running") {
    super("a build of this brief is queued or running");
  }
}

/** A held-out check already bound to a build of this brief (ADR 0029: every new build gets a fresh one). */
export class HeldOutUsed extends Error {
  constructor() {
    super("this held-out check was already used by a build of this brief");
  }
}

/** The build already ended (stale recovery, or another writer): its orchestrator must stop and write nothing more. */
export class BuildEnded extends Error {
  constructor() {
    super("the build already ended");
  }
}

export interface BuildStore {
  /** One transaction: a live, fresh build of the brief is BuildConflict; a held-out hash any earlier build of the
   * brief was bound to is HeldOutUsed (and nothing is recovered); stale live builds are ended infra_failed. */
  insertQueued(b: NewBuild, now: number, stale_after_ms: number): Promise<BuildRow>;
  /** True when any build of this brief was bound to this held-out hash (ADR 0029). */
  heldOutUsed(tenant_id: string, brief_id: string, held_out_hash: string): Promise<boolean>;
  get(tenant_id: string, id: string): Promise<BuildRow | null>;
  /** Applies the patch and sets heartbeat_at = now. Throws BuildEnded when the build is no longer live. */
  update(tenant_id: string, id: string, patch: BuildPatch, now: number): Promise<BuildRow>;
  putAttempt(a: AttemptRow): Promise<void>;
  attempts(tenant_id: string, build_id: string): Promise<AttemptRow[]>;
  /** Under a lock on the build: settled + open reservations + this one must stay within the ceiling. */
  reserve(r: Reservation, now: number): Promise<boolean>;
  /** Writes the budget entry once per idempotency key and settles the call's reservation. */
  settle(s: Settlement, now: number): Promise<void>;
  /** Sets deployed_at once on a ready build; false when it was already set or the build is not ready. */
  markDeployed(tenant_id: string, id: string, now: number): Promise<boolean>;
  /** Clears deployed_at when the deploy failed before a routine existed, so it can be retried. */
  unmarkDeployed(tenant_id: string, id: string): Promise<void>;
  /** queued -> building, once: true for the one caller that made the change (sets started_at and heartbeat_at). */
  startBuild(tenant_id: string, id: string, now: number): Promise<boolean>;
  /** Moves heartbeat_at to now. Throws BuildEnded when the build is no longer live. */
  heartbeat(tenant_id: string, id: string, now: number): Promise<void>;
}

export const staleNote = "Offload's side stopped: no progress for longer than any stage can take. Ended so a new build can start.";

export interface BudgetEntry extends Settlement {
  at: number;
}

/** In-memory BuildStore. Each method does its checks and writes after its last await, so it is atomic in-process. */
export class MemoryBuildStore implements BuildStore {
  readonly builds = new Map<string, BuildRow>();
  readonly attemptRows = new Map<string, AttemptRow>();
  readonly reservations: Array<Reservation & { created_at: number; settled_at: number | null }> = [];
  readonly entries: BudgetEntry[] = [];
  private key = (t: string, id: string) => `${t}/${id}`;

  async insertQueued(b: NewBuild, now: number, stale_after_ms: number): Promise<BuildRow> {
    const same = [...this.builds.values()].filter((x) => x.tenant_id === b.tenant_id && x.brief_id === b.brief_id);
    for (const x of same) if (isLive(x.state) && now - x.heartbeat_at <= stale_after_ms) throw new BuildConflict("already_running");
    if (same.some((x) => x.bound_hashes["held_out_hash"] === b.bound_hashes["held_out_hash"])) throw new HeldOutUsed();
    for (const x of same) {
      if (!isLive(x.state)) continue;
      x.state = "infra_failed";
      x.ended_at = now;
      x.heartbeat_at = now;
      x.stages = [...x.stages, { name: "recovered", state: "failed", started_at: now, ended_at: now, note: staleNote }];
    }
    const row: BuildRow = { ...b, bound_hashes: { ...b.bound_hashes }, approval_id: null, state: "queued", spent_usd4: 0, infra_retries: 0, stages: [], winner_attempt_id: null, artifact_sha256: null, receipt_hash: null, definition_hash: null, receipt: null, created_at: now, heartbeat_at: now, started_at: null, ended_at: null, deployed_at: null };
    this.builds.set(this.key(b.tenant_id, b.id), row);
    return structuredClone(row);
  }

  async heldOutUsed(tenant_id: string, brief_id: string, held_out_hash: string): Promise<boolean> {
    return [...this.builds.values()].some((x) => x.tenant_id === tenant_id && x.brief_id === brief_id && x.bound_hashes["held_out_hash"] === held_out_hash);
  }

  async get(tenant_id: string, id: string): Promise<BuildRow | null> {
    const b = this.builds.get(this.key(tenant_id, id));
    return b === undefined ? null : structuredClone(b);
  }

  async update(tenant_id: string, id: string, patch: BuildPatch, now: number): Promise<BuildRow> {
    const b = this.builds.get(this.key(tenant_id, id));
    if (b === undefined) throw new Error("no such build");
    if (!isLive(b.state)) throw new BuildEnded();
    Object.assign(b, structuredClone(patch), { heartbeat_at: now });
    return structuredClone(b);
  }

  async putAttempt(a: AttemptRow): Promise<void> {
    this.attemptRows.set(this.key(a.tenant_id, a.id), structuredClone(a));
  }

  async attempts(tenant_id: string, build_id: string): Promise<AttemptRow[]> {
    return [...this.attemptRows.values()].filter((a) => a.tenant_id === tenant_id && a.build_id === build_id).sort((x, y) => x.ordinal - y.ordinal).map((a) => structuredClone(a));
  }

  async reserve(r: Reservation, now: number): Promise<boolean> {
    const b = this.builds.get(this.key(r.tenant_id, r.build_id));
    if (b === undefined) return false;
    const open = this.reservations.filter((x) => x.tenant_id === r.tenant_id && x.build_id === r.build_id && x.settled_at === null).reduce((t, x) => t + x.usd4, 0);
    if (b.spent_usd4 + open + r.usd4 > r.ceiling_usd4 || r.usd4 <= 0) return false;
    this.reservations.push({ ...r, created_at: now, settled_at: null });
    return true;
  }

  async settle(s: Settlement, now: number): Promise<void> {
    if (!this.entries.some((e) => e.tenant_id === s.tenant_id && e.idempotency_key === s.idempotency_key)) {
      this.entries.push({ ...s, at: now });
      const b = this.builds.get(this.key(s.tenant_id, s.build_id));
      if (b !== undefined && s.scope === "build") b.spent_usd4 += s.usd4;
    }
    for (const x of this.reservations) if (x.tenant_id === s.tenant_id && x.build_id === s.build_id && x.call_id === s.call_id && x.settled_at === null) x.settled_at = now;
  }

  async markDeployed(tenant_id: string, id: string, now: number): Promise<boolean> {
    const b = this.builds.get(this.key(tenant_id, id));
    if (b === undefined || b.state !== "ready" || b.deployed_at !== null) return false;
    b.deployed_at = now;
    return true;
  }

  async unmarkDeployed(tenant_id: string, id: string): Promise<void> {
    const b = this.builds.get(this.key(tenant_id, id));
    if (b !== undefined) b.deployed_at = null;
  }

  async startBuild(tenant_id: string, id: string, now: number): Promise<boolean> {
    const b = this.builds.get(this.key(tenant_id, id));
    if (b === undefined || b.state !== "queued" || b.approval_id === null) return false;
    Object.assign(b, { state: "building", started_at: now, heartbeat_at: now });
    return true;
  }

  async heartbeat(tenant_id: string, id: string, now: number): Promise<void> {
    const b = this.builds.get(this.key(tenant_id, id));
    if (b === undefined || !isLive(b.state)) throw new BuildEnded();
    b.heartbeat_at = now;
  }
}
