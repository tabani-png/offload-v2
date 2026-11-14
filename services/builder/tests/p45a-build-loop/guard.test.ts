// The container guard (473cafb's main fix, old container-guard.test.ts): a check shard must not load anything the
// worker planted in its artifact (bunfig.toml preload, node_modules package, tsconfig paths, package.json imports, .env).
// Any of those could run worker code inside the check process and fake a PASS. Real bun, real planted files on disk:
// the Docker provider is used with an executor that emulates `docker run` (mounts mapped to the sandbox's host folders,
// --workdir as cwd, --env as the whole environment), so the attack is exercised on any machine without Docker.
import { afterAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { GUARD_TS, SHARD_BUNFIG } from "../../src/harness.ts";
import { DockerProvider, type Executor } from "../../src/sandbox/docker.ts";
import type { SandboxFile, SandboxSpec } from "../../src/sandbox/provider.ts";
import { runShards } from "../../src/shards.ts";
import { checkSet, file } from "./setup.ts";

const temps: string[] = [];
const tmp = (p = "offload-p45a-guard-") => {
  const d = mkdtempSync(join(tmpdir(), p));
  temps.push(d);
  return d;
};
afterAll(() => {
  for (const d of temps) rmSync(d, { recursive: true, force: true });
});

/** Runs the command of a `docker run` argv with local bun; container paths are mapped to the sandbox's host folders. */
const emulate: Executor = async (argv, o) => {
  if (argv[1] !== "run") return { exit: 0, stdout: "", stderr: "", timed_out: false };
  const maps: Array<[string, string]> = [];
  const env: Record<string, string> = {};
  let workdir = "/";
  let i = 2;
  for (; i < argv.length; i++) {
    const a = argv[i]!;
    if (a === "--rm" || a === "-i" || a === "--read-only") continue;
    if (!a.startsWith("-")) break;
    const v = argv[++i]!;
    if (a === "--mount") {
      const kv = Object.fromEntries(v.split(",").filter((p) => p.includes("=")).map((p) => p.split("=") as [string, string]));
      maps.push([kv["target"]!, kv["source"]!]);
    } else if (a === "--tmpfs") maps.push([v.split(":")[0]!, tmp("offload-p45a-tmpfs-")]);
    else if (a === "--workdir") workdir = v;
    else if (a === "--env") env[v.slice(0, v.indexOf("="))] = v.slice(v.indexOf("=") + 1);
  }
  const targets = maps.map((m) => m[0]).sort((a, b) => b.length - a.length);
  // One rewrite per value: the host folders themselves live under the host's /tmp, which is also a container path.
  const map = (s: string) => {
    for (const c of targets) {
      const re = new RegExp(`(^|=)${c.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?=/|$)`);
      if (re.test(s)) return s.replace(re, `$1${maps.find((m) => m[0] === c)![1]}`);
    }
    return s;
  };
  const cmd = argv.slice(i + 1).map(map);
  expect(cmd[0]).toBe("bun");
  cmd[0] = process.execPath;
  const p = Bun.spawn(cmd, {
    cwd: map(workdir),
    env: { PATH: process.env["PATH"] ?? "/usr/bin:/bin", ...Object.fromEntries(Object.entries(env).map(([k, v]) => [k, map(v)])) },
    stdin: new TextEncoder().encode(o.stdin ?? ""),
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, exit] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  return { exit, stdout, stderr, timed_out: false };
};

/** Worker code that turns a failing bun test run into exit 0 once loaded into the check process. */
const PAYLOAD = 'import { afterAll } from "bun:test";\nafterAll(() => process.exit(0));\nexport {};\n';
const FAILING_CHECK = 'import { expect, test } from "bun:test";\ntest("the tool works", () => { expect(1).toBe(2); });\n';
const TOOL = 'console.log("slug:" + (process.argv[2] ?? "").toLowerCase());\n';

/** Every file below would turn a failing check into exit 0 if bun loaded it into the check process. */
function plantedArtifact(): SandboxFile[] {
  return [
    file("evil.ts", PAYLOAD),
    file("bunfig.toml", 'preload = ["./evil.ts"]\n\n[test]\npreload = ["./evil.ts"]\n'),
    file("node_modules/helper/package.json", JSON.stringify({ name: "helper", main: "index.js" })),
    file("node_modules/helper/index.js", 'const { afterAll } = require("bun:test");\nafterAll(() => process.exit(0));\n'),
    file("tsconfig.json", JSON.stringify({ compilerOptions: { paths: { "@check/*": ["./evil.ts"] } } })),
    file("package.json", JSON.stringify({ name: "built", imports: { "#h": "./evil.ts" } })),
    file(".env", "OFFLOAD_PLANTED=1\n"),
    file("tool.ts", TOOL),
  ];
}

const SPEC: SandboxSpec = { image: "offload-check:test", vcpu: 1, memory_mb: 1024, wall_ms: 300_000, network_allowlist: [], env: {}, tag: "offload-build-guard", role: "verification" };
const provider = new DockerProvider({ executor: emulate, docker: "docker" });
afterAll(async () => {
  for (const s of provider.known()) await provider.destroy(s).catch(() => {});
});
const run = async (content: string, artifact = plantedArtifact()) =>
  (await runShards({ provider, spec: SPEC, artifact, shards: [{ name: "held_out", check: checkSet("held_out", content) }], timeout_ms: 60_000 }))[0]!;

describe("p45a container guard", () => {
  test("SHARDS: (control) the planted payload really fakes a pass once bun loads it into a check", () => {
    const ws = tmp();
    for (const f of plantedArtifact()) {
      mkdirSync(join(ws, f.path, ".."), { recursive: true });
      writeFileSync(join(ws, f.path), f.bytes);
    }
    const env = { PATH: process.env["PATH"] ?? "/usr/bin:/bin", HOME: ws };
    writeFileSync(join(ws, "ctl.test.ts"), `import "./evil.ts";\n${FAILING_CHECK}`);
    expect(Bun.spawnSync([process.execPath, "test", "--no-env-file", "./ctl.test.ts"], { cwd: ws, env, stdout: "pipe", stderr: "pipe" }).exitCode).toBe(0);
    // the planted bunfig.toml alone is enough when the check runs with cwd = the artifact (the old shard layout)
    writeFileSync(join(ws, "ctl2.test.ts"), FAILING_CHECK);
    expect(Bun.spawnSync([process.execPath, "test", "--no-env-file", "./ctl2.test.ts"], { cwd: ws, env, stdout: "pipe", stderr: "pipe" }).exitCode).toBe(0);
  });

  test("SHARDS: a builder-planted bunfig.toml preload in the artifact cannot fake a PASS", async () => {
    const r = await run(FAILING_CHECK);
    expect(r.passed).toBe(false);
    expect(r.proof?.status).toBe("fail");
  });

  test("SHARDS: a builder-planted node_modules package, tsconfig path or package imports entry is never loaded", async () => {
    for (const spec of ["helper", "@check/x", "#h", "/work/evil.ts", "../work/evil.ts"]) {
      const check = `import { expect, test } from "bun:test";\nimport ${JSON.stringify(spec)};\ntest("the tool works", () => { expect(1).toBe(2); });\n`;
      const r = await run(check);
      expect([spec, r.passed]).toEqual([spec, false]);
    }
  });

  test("SHARDS: worker code imported by a check is refused, even when it would make the check pass", async () => {
    // The check writer's mistake (importing the built code) must not hand the verdict to the worker: without the guard
    // the worker's module runs inside the check process and answers whatever the check asks.
    const api = file("api.ts", "export const verdict = () => true;\n");
    for (const spec of ["../work/api.ts", "/work/api.ts"]) {
      const check = `import { expect, test } from "bun:test";\nimport { verdict } from ${JSON.stringify(spec)};\ntest("the tool works", () => { expect(verdict()).toBe(true); });\n`;
      const r = await run(check, [api]);
      expect([spec, r.passed]).toEqual([spec, false]);
    }
  });

  test("SHARDS: a builder-planted .env is not loaded into the check", async () => {
    const check = 'import { expect, test } from "bun:test";\ntest("no planted env", () => { expect(process.env["OFFLOAD_PLANTED"]).toBeUndefined(); });\n';
    const r = await run(check);
    expect(r.output).not.toContain("OFFLOAD_PLANTED=1");
    expect(r.passed).toBe(true);
  });

  test("SHARDS: an honest check still runs the built tool as a subprocess from the artifact copy and passes", async () => {
    const check = [
      'import { expect, test } from "bun:test";',
      'test("slugs", () => {',
      '  const p = Bun.spawnSync([process.execPath, "run", "tool.ts", "Hello"]);',
      '  expect(p.stdout.toString().trim()).toBe("slug:hello");',
      "});",
      "",
    ].join("\n");
    const r = await run(check, [file("tool.ts", TOOL)]);
    expect(r.proof).toMatchObject({ status: "pass", tests: 1 });
    expect(r.passed).toBe(true);
  });

  test("SHARDS: the check folder holds the guard preload, and the check runs outside /work", async () => {
    const seen: string[][] = [];
    const files: Record<string, string> = {};
    const spy = new DockerProvider({
      docker: "docker",
      executor: async (argv) => {
        if (argv[1] === "run") {
          seen.push(argv);
          const mount = argv.find((a) => a.includes("target=/check"))!;
          const src = /source=([^,]+)/.exec(mount)![1]!;
          for (const f of ["guard.ts", "bunfig.toml", "accept.test.ts", "harness.ts"]) files[f] = readFileSync(join(src, f), "utf8");
        }
        return { exit: 1, stdout: "", stderr: "", timed_out: false };
      },
    });
    await runShards({ provider: spy, spec: SPEC, artifact: plantedArtifact(), shards: [{ name: "held_out", check: checkSet("held_out", FAILING_CHECK) }], timeout_ms: 1000 });
    const a = seen[0]!;
    expect(files["guard.ts"]).toBe(GUARD_TS);
    expect(files["bunfig.toml"]).toBe(SHARD_BUNFIG);
    expect(files["bunfig.toml"]).toContain("guard.ts");
    expect(files["accept.test.ts"]).toBe(FAILING_CHECK);
    expect(files["harness.ts"]).toContain("--no-env-file");
    expect(files["harness.ts"]).toContain("--config=");
    const mount = a.find((x) => x.includes("target=/check"))!;
    expect(mount).toMatch(/,readonly$/);
    expect(a[a.indexOf("--workdir") + 1]).toBe("/check");
    expect(a).toContain("OFFLOAD_WS=/work");
  });
});
