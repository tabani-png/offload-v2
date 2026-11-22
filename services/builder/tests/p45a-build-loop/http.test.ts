// /v1 build handlers (old surfaces.test.ts and routes-hardening.test.ts): framework-agnostic web-standard
// Request -> Response, mounted later by services/api. API.md error envelope and codes.
import { describe, expect, test } from "bun:test";
import { buildRoutes, InlineBuildRunner } from "../../src/http.ts";
import type { RoutinePort } from "../../src/routines.ts";
import { checkSet, FIX, harness, hashesOf, HELDOUT_CONTENT, MEMBER, OTHER_TENANT, TENANT } from "./setup.ts";

function api(scripts = [{}], o: Parameters<typeof harness>[1] = {}) {
  const h = harness(scripts, o);
  const runner = new InlineBuildRunner(h.deps);
  const deployed: unknown[] = [];
  const routines: RoutinePort = {
    async deploy(i) {
      deployed.push(i);
      return { routine_id: "0193a6f2-0000-7000-8000-00000000r001", version: 1 };
    },
  };
  const route = buildRoutes({ ...h.deps, runner, routines });
  const call = async (method: string, path: string, body?: unknown, tenant = TENANT) => {
    const req = new Request(`http://offload.test${path}`, { method, ...(body === undefined ? {} : { body: typeof body === "string" ? body : JSON.stringify(body), headers: { "content-type": "application/json" } }) });
    const res = await route(req, { tenant_id: tenant, member_id: MEMBER });
    if (res === null) return { status: 0, body: null as any };
    return { status: res.status, body: (await res.json()) as any };
  };
  return { ...h, runner, call, deployed };
}

describe("p45a /v1 builds", () => {
  test("API: OK, build with the exact hashes starts the build (202) and the build ends ready", async () => {
    const a = api();
    const r = await a.call("POST", `/v1/fixes/${FIX}/build-approvals`, hashesOf(a.fix));
    expect(r.status).toBe(202);
    expect(Object.keys(r.body)).toEqual(["build_id"]);
    await a.runner.idle();
    const g = await a.call("GET", `/v1/builds/${r.body.build_id}`);
    expect(g.status).toBe(200);
    expect(g.body.state).toBe("ready");
  });

  test("GATE: a wrong brief hash is refused as forbidden (403 hash_mismatch) before any check is written or any worker runs; so is any other wrong hash or cap", async () => {
    const a = api();
    for (const k of ["brief_hash", "check_set_hash", "held_out_hash", "fixture_set_hash"]) {
      const r = await a.call("POST", `/v1/fixes/${FIX}/build-approvals`, { ...hashesOf(a.fix), [k]: "0".repeat(64) });
      expect([k, r.status, r.body.error.code]).toEqual([k, 403, "hash_mismatch"]);
      expect(r.body.error.request_id).toMatch(/^req_/);
    }
    const cap = await a.call("POST", `/v1/fixes/${FIX}/build-approvals`, { ...hashesOf(a.fix), cap_usd: 40 });
    expect([cap.status, cap.body.error.code]).toEqual([403, "hash_mismatch"]);
    await a.runner.idle();
    expect(a.store.builds.size).toBe(0);
    expect(a.approvals.rows.size).toBe(0);
    expect(a.provider.sandboxes).toHaveLength(0);
    expect(a.worker.turns).toHaveLength(0);
  });

  test("API: a bad body is 400 invalid_request; an unknown fix or build is 404; other paths are not handled", async () => {
    const a = api();
    for (const body of ["not json", { brief_hash: "x" }, { ...hashesOf(a.fix), cap_usd: "4.00" }, { ...hashesOf(a.fix), brief_hash: "A".repeat(64) }]) {
      const r = await a.call("POST", `/v1/fixes/${FIX}/build-approvals`, body);
      expect([r.status, r.body.error.code]).toEqual([400, "invalid_request"]);
    }
    expect((await a.call("POST", "/v1/fixes/fix_unknown/build-approvals", hashesOf(a.fix))).status).toBe(404);
    expect((await a.call("GET", "/v1/builds/0193a6f2-0000-7000-8000-000000000999")).status).toBe(404);
    expect((await a.call("GET", "/v1/routines")).status).toBe(0);
  });

  test("LOCK: two OKs of the same brief at once: exactly one 202, the other 409 already_running", async () => {
    const a = api([{ delayMs: 20 }]);
    const rs = await Promise.all([1, 2].map(() => a.call("POST", `/v1/fixes/${FIX}/build-approvals`, hashesOf(a.fix))));
    expect(rs.map((r) => r.status).sort()).toEqual([202, 409]);
    expect(rs.find((r) => r.status === 409)!.body.error.code).toBe("already_running");
    await a.runner.idle();
    const ok = rs.find((r) => r.status === 202)!;
    expect((await a.call("GET", `/v1/builds/${ok.body.build_id}`)).body.state).toBe("ready");
    expect(a.store.builds.size).toBe(1);
  });

  test("HELDOUT: a new OK of the same brief with an already used held_out_hash is refused (409 state_conflict)", async () => {
    const a = api();
    expect((await a.call("POST", `/v1/fixes/${FIX}/build-approvals`, hashesOf(a.fix))).status).toBe(202);
    await a.runner.idle();
    const again = await a.call("POST", `/v1/fixes/${FIX}/build-approvals`, hashesOf(a.fix));
    expect([again.status, again.body.error.code]).toEqual([409, "state_conflict"]);
    const fresh = checkSet("held_out", HELDOUT_CONTENT.replace("edges", "edges again"));
    a.fixes.fixes.get(`${TENANT}/${FIX}`)!.held_out = fresh;
    expect((await a.call("POST", `/v1/fixes/${FIX}/build-approvals`, { ...hashesOf(a.fix), held_out_hash: fresh.hash })).status).toBe(202);
    await a.runner.idle();
  });

  test("DEPLOY: deploy with a wrong definition_hash is 403; deploy of a build not ready is 409", async () => {
    const a = api([{ delayMs: 30 }]);
    const ok = await a.call("POST", `/v1/fixes/${FIX}/build-approvals`, hashesOf(a.fix));
    const early = await a.call("POST", `/v1/builds/${ok.body.build_id}/deploy`, { artifact_sha256: "a".repeat(64), receipt_hash: "b".repeat(64), definition_hash: "c".repeat(64) });
    expect([early.status, early.body.error.code]).toEqual([409, "state_conflict"]);
    await a.runner.idle();
    const b = (await a.call("GET", `/v1/builds/${ok.body.build_id}`)).body;
    const good = { artifact_sha256: b.artifact_sha256, receipt_hash: b.receipt_hash, definition_hash: b.definition_hash };
    for (const k of Object.keys(good)) {
      const r = await a.call("POST", `/v1/builds/${ok.body.build_id}/deploy`, { ...good, [k]: "f".repeat(64) });
      expect([k, r.status, r.body.error.code]).toEqual([k, 403, "hash_mismatch"]);
    }
    expect(a.deployed).toHaveLength(0);
  });

  test("SHIP: deploying the same build twice is refused (409 state_conflict); the first routine stands", async () => {
    const a = api();
    const ok = await a.call("POST", `/v1/fixes/${FIX}/build-approvals`, hashesOf(a.fix));
    await a.runner.idle();
    const b = (await a.call("GET", `/v1/builds/${ok.body.build_id}`)).body;
    const body = { artifact_sha256: b.artifact_sha256, receipt_hash: b.receipt_hash, definition_hash: b.definition_hash };
    const both = await Promise.all([1, 2].map(() => a.call("POST", `/v1/builds/${ok.body.build_id}/deploy`, body)));
    expect(both.map((r) => r.status).sort()).toEqual([201, 409]);
    expect(both.find((r) => r.status === 201)!.body).toEqual({ routine_id: "0193a6f2-0000-7000-8000-00000000r001", version: 1 });
    expect(a.deployed).toHaveLength(1);
    const deploys = [...a.approvals.rows.values()].filter((x) => x.kind === "deploy");
    expect(deploys).toHaveLength(1);
    expect(deploys[0]!.claimed_at).not.toBeNull();
    expect(deploys[0]!.bound_hashes).toEqual(body);
    expect((await a.call("POST", `/v1/builds/${ok.body.build_id}/deploy`, body)).status).toBe(409);
  });

  test("SHIP: a deploy that fails after the approval leaves the build deployable again, and a retry deploys it once", async () => {
    const a = api();
    let fail = true;
    const real = a.deployed;
    const route = buildRoutes({ ...a.deps, runner: a.runner, routines: { async deploy() { if (fail) throw new Error("runtime down"); real.push(1); return { routine_id: "r", version: 1 }; } } });
    const ok = await a.call("POST", `/v1/fixes/${FIX}/build-approvals`, hashesOf(a.fix));
    await a.runner.idle();
    const b = (await a.call("GET", `/v1/builds/${ok.body.build_id}`)).body;
    const body = JSON.stringify({ artifact_sha256: b.artifact_sha256, receipt_hash: b.receipt_hash, definition_hash: b.definition_hash });
    const post = () => route(new Request(`http://offload.test/v1/builds/${ok.body.build_id}/deploy`, { method: "POST", body, headers: { "content-type": "application/json" } }), { tenant_id: TENANT, member_id: MEMBER });
    expect((await post())!.status).toBe(500);
    expect((await a.call("GET", `/v1/builds/${ok.body.build_id}`)).body.deployed).toBe(false);
    fail = false;
    expect((await post())!.status).toBe(201);
    expect((await post())!.status).toBe(409);
    expect(real).toHaveLength(1);
  });

  test("SHIP: every deploy call carries the build id as its idempotency key, so a retry after a timeout cannot make a second routine", async () => {
    const a = api();
    const keys: string[] = [];
    let fail = true;
    const route = buildRoutes({ ...a.deps, runner: a.runner, routines: { async deploy(i) { keys.push(i.idempotency_key); if (fail) throw new Error("timeout after the version was created"); return { routine_id: "r", version: 1 }; } } });
    const ok = await a.call("POST", `/v1/fixes/${FIX}/build-approvals`, hashesOf(a.fix));
    await a.runner.idle();
    const b = (await a.call("GET", `/v1/builds/${ok.body.build_id}`)).body;
    const body = JSON.stringify({ artifact_sha256: b.artifact_sha256, receipt_hash: b.receipt_hash, definition_hash: b.definition_hash });
    const post = () => route(new Request(`http://offload.test/v1/builds/${ok.body.build_id}/deploy`, { method: "POST", body, headers: { "content-type": "application/json" } }), { tenant_id: TENANT, member_id: MEMBER });
    expect((await post())!.status).toBe(500);
    fail = false;
    expect((await post())!.status).toBe(201);
    expect(keys).toEqual([`deploy:${ok.body.build_id}`, `deploy:${ok.body.build_id}`]);
  });

  test("API: GET /v1/builds/{id} shows state, spend against the cap, stages and attempts with check groups; never another tenant's", async () => {
    const a = api();
    const ok = await a.call("POST", `/v1/fixes/${FIX}/build-approvals`, hashesOf(a.fix));
    await a.runner.idle();
    const g = (await a.call("GET", `/v1/builds/${ok.body.build_id}`)).body;
    expect(g).toMatchObject({ id: ok.body.build_id, state: "ready", cap_usd: 4, fanout_workers: 1 });
    expect(g.spent_usd).toBe(0.1);
    expect(g.stages.map((s: { name: string }) => s.name)).toEqual(["teeth_gate", "worker", "verification", "winner"]);
    expect(g.attempts[0]).toMatchObject({ ordinal: 1, outcome: "pass", check_groups: [{ name: "frozen", passed: 1, failed: 0 }, { name: "held_out", passed: 1, failed: 0 }] });
    expect(JSON.stringify(g)).not.toContain("approval_id");
    expect(JSON.stringify(g)).not.toContain("token");
    expect((await a.call("GET", `/v1/builds/${ok.body.build_id}`, undefined, OTHER_TENANT)).status).toBe(404);
  });
});
