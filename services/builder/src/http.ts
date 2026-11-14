// /v1 build handlers (old builder/routes.ts, rewritten): framework-agnostic, web-standard Request -> Response, so
// services/api mounts them under its auth (it resolves the principal and passes tenant_id and member_id). API.md
// shapes and the closed error-code list. The approval token never appears in a response, a log or a stored row.
//   POST /v1/fixes/{id}/build-approvals   OK, build
//   GET  /v1/builds/{id}                  Build
//   POST /v1/builds/{id}/deploy           deploy approval (once)
import { randomBytes } from "node:crypto";
import { fromUsd4 } from "./config.ts";
import { HEX64 } from "./hash.ts";
import { OkBuildError, okBuild, runBuild, type BuildDeps } from "./loop.ts";
import type { RoutinePort } from "./routines.ts";
import type { AttemptRow, BuildRow } from "./store.ts";

/** The durable runtime's start, as the builder uses it (W1-C). Inputs are ids; the token is handed over in process. */
export interface BuildRunner {
  start(i: { tenant_id: string; build_id: string }, token: string): void;
}

/** Runs the build in this process (tests, dev). The durable adapter replaces it (DESIGN.md section 4). */
export class InlineBuildRunner implements BuildRunner {
  private readonly running = new Set<Promise<void>>();
  constructor(private readonly deps: BuildDeps) {}
  start(i: { tenant_id: string; build_id: string }, token: string): void {
    const p = runBuild(this.deps, { ...i, token }).catch(() => undefined);
    this.running.add(p);
    void p.finally(() => this.running.delete(p));
  }
  async idle(): Promise<void> {
    while (this.running.size > 0) await Promise.all([...this.running]);
  }
}

export interface HttpDeps extends BuildDeps {
  runner: BuildRunner;
  routines: RoutinePort;
}

type Code = "invalid_request" | "not_found" | "hash_mismatch" | "already_running" | "state_conflict" | "server_error";
const STATUS: Record<Code, number> = { invalid_request: 400, not_found: 404, hash_mismatch: 403, already_running: 409, state_conflict: 409, server_error: 500 };
const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const requestId = () => `req_${Array.from(randomBytes(26), (b) => CROCKFORD[b % 32]).join("")}`;
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
const error = (code: Code, message: string) => json(STATUS[code], { error: { code, message, request_id: requestId() } });

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const FIX_ID = /^[A-Za-z0-9_-]{1,64}$/;
const iso = (ms: number | null) => (ms === null ? null : new Date(ms).toISOString());

async function readJson(req: Request): Promise<unknown | undefined> {
  try {
    const text = await req.text();
    if (text.length > 16_384) return undefined;
    return JSON.parse(text) as unknown;
  } catch {
    return undefined;
  }
}

/** The API.md `Build` shape: ids, states, Figures-ready numbers, hashes. No approval id, token, path or held-out text. */
export function buildView(b: BuildRow, attempts: AttemptRow[]) {
  return {
    id: b.id,
    state: b.state,
    cap_usd: fromUsd4(b.cap_usd4),
    spent_usd: fromUsd4(b.spent_usd4),
    fanout_workers: b.fanout_workers,
    stages: b.stages.map((s) => ({ name: s.name, state: s.state, started_at: iso(s.started_at), ended_at: iso(s.ended_at), note: s.note })),
    attempts: attempts.map((a) => ({ id: a.id, ordinal: a.ordinal, outcome: a.outcome, spent_usd: fromUsd4(a.spent_usd4), tries: a.tries, turns: a.turns, frozen_pass: a.frozen_pass, held_out_pass: a.held_out_pass, check_groups: a.check_groups, artifact_sha256: a.artifact_sha256, artifact_bytes: a.artifact_bytes, artifact_files: a.artifact_files, note: a.note })),
    winner_attempt_id: b.winner_attempt_id,
    artifact_sha256: b.artifact_sha256,
    receipt_hash: b.receipt_hash,
    definition_hash: b.definition_hash,
    deployed: b.deployed_at !== null,
    started_at: iso(b.started_at),
    ended_at: iso(b.ended_at),
  };
}

export function buildRoutes(d: HttpDeps): (req: Request, ctx: { tenant_id: string; member_id: string }) => Promise<Response | null> {
  return async (req, ctx) => {
    const path = new URL(req.url).pathname;
    try {
      let m = /^\/v1\/fixes\/([^/]+)\/build-approvals$/.exec(path);
      if (m !== null && req.method === "POST") {
        if (!FIX_ID.test(m[1]!)) return error("not_found", "no such fix");
        const body = await readJson(req);
        if (body === undefined) return error("invalid_request", "the body must be JSON");
        try {
          const r = await okBuild(d, { tenant_id: ctx.tenant_id, member_id: ctx.member_id, fix_id: m[1]!, body });
          d.runner.start({ tenant_id: ctx.tenant_id, build_id: r.build_id }, r.token);
          return json(202, { build_id: r.build_id });
        } catch (e) {
          if (e instanceof OkBuildError) return error(e.code, e.message);
          throw e;
        }
      }
      m = /^\/v1\/builds\/([^/]+)$/.exec(path);
      if (m !== null && req.method === "GET") {
        if (!UUID.test(m[1]!)) return error("not_found", "no such build");
        const b = await d.store.get(ctx.tenant_id, m[1]!);
        if (b === null) return error("not_found", "no such build");
        return json(200, buildView(b, await d.store.attempts(ctx.tenant_id, b.id)));
      }
      m = /^\/v1\/builds\/([^/]+)\/deploy$/.exec(path);
      if (m !== null && req.method === "POST") return await deploy(d, ctx, m[1]!, req);
      return null;
    } catch {
      return error("server_error", "Offload's side failed");
    }
  };
}

async function deploy(d: HttpDeps, ctx: { tenant_id: string; member_id: string }, id: string, req: Request): Promise<Response> {
  if (!UUID.test(id)) return error("not_found", "no such build");
  const b = await d.store.get(ctx.tenant_id, id);
  if (b === null) return error("not_found", "no such build");
  const body = await readJson(req);
  const keys = ["artifact_sha256", "receipt_hash", "definition_hash"] as const;
  if (typeof body !== "object" || body === null || keys.some((k) => typeof (body as Record<string, unknown>)[k] !== "string" || !HEX64.test((body as Record<string, string>)[k]!))) {
    return error("invalid_request", "artifact_sha256, receipt_hash and definition_hash must be sha256 hex");
  }
  const got = body as Record<(typeof keys)[number], string>;
  if (b.state !== "ready" || b.deployed_at !== null) return error("state_conflict", b.deployed_at !== null ? "this build is already deployed" : "only a ready build can be deployed");
  if (b.artifact_sha256 === null || b.receipt_hash === null || b.definition_hash === null) return error("state_conflict", "this build has no routine definition to deploy");
  const want = { artifact_sha256: b.artifact_sha256, receipt_hash: b.receipt_hash, definition_hash: b.definition_hash };
  for (const k of keys) if (got[k] !== want[k]) return error("hash_mismatch", `${k} is not this build's: read the definition again`);
  // Once: the first deploy sets deployed_at; any other gets state_conflict and changes nothing.
  if (!(await d.store.markDeployed(ctx.tenant_id, id, d.now()))) return error("state_conflict", "this build is already deployed");
  try {
    const a = await d.approvals.mint({ tenant_id: ctx.tenant_id, kind: "deploy", subject_id: id, bound: want, approver_kind: "person", approver_member_id: ctx.member_id }, d.now());
    await d.approvals.claim({ tenant_id: ctx.tenant_id, approval_id: a.approval_id, token: a.token, bound: want, kind: "deploy", subject_id: id }, d.now());
    const r = await d.routines.deploy({ tenant_id: ctx.tenant_id, member_id: ctx.member_id, build_id: id, ...want });
    return json(201, r);
  } catch (e) {
    // No routine was created: the build may be deployed again (a new deploy approval is minted then).
    await d.store.unmarkDeployed(ctx.tenant_id, id).catch(() => undefined);
    throw e;
  }
}
