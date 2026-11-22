// The container guard (473cafb's main fix, old container-guard.test.ts): a check shard must not load anything the
// worker planted in its artifact (bunfig.toml preload, node_modules package, tsconfig paths, package.json imports, .env).
// Any of those could run worker code inside the check process and fake a PASS. Real bun, real planted files on disk:
// the Docker provider is used with an executor that emulates `docker run` (mounts mapped to the sandbox's host folders,
// --workdir as cwd, --env as the whole environment), so the attack is exercised on any machine without Docker.
import { afterAll, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BUILDER_IMPORT_REFUSED, GUARD_TS, SHARD_BUNFIG } from "../../src/harness.ts";
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
  for (const d of temps) {
    try {
      rmSync(d, { recursive: true, force: true });
    } catch {
      // the privileged tests' root harness leaves root-owned files (bun's cache) in the emulated /tmp
      Bun.spawnSync(["sudo", "-n", "rm", "-rf", d]);
    }
  }
});

/** Runs the command of a `docker run` argv locally; container paths are mapped to the sandbox's host folders.
 * With `sudo`, the argv's `--user` and `--cap-add` are honoured through setpriv, exactly as the container gets them:
 * `--user 0:0` runs as root with ONLY the added capabilities (bounding set, no inheritable, no-new-privs; for the
 * harness that is CHOWN, SETGID and SETUID), any other `--user u:g` runs as that user with no capability. So the
 * check and the built tool really run as two different users, under the container's real capability set. */
const emulator = (o2: { sudo: boolean }): Executor => async (argv, o) => {
  if (argv[1] !== "run") return { exit: 0, stdout: "", stderr: "", timed_out: false };
  const maps: Array<[string, string]> = [];
  const mounts: string[] = [];
  const env: Record<string, string> = {};
  let workdir = "/";
  let entrypoint: string | null = null;
  let user = "";
  const caps: string[] = [];
  let i = 2;
  for (; i < argv.length; i++) {
    const a = argv[i]!;
    if (a === "--rm" || a === "-i" || a === "--read-only") continue;
    if (!a.startsWith("-")) break;
    const v = argv[++i]!;
    if (a === "--mount") {
      const kv = Object.fromEntries(v.split(",").filter((p) => p.includes("=")).map((p) => p.split("=") as [string, string]));
      maps.push([kv["target"]!, kv["source"]!]);
      mounts.push(kv["source"]!);
    } else if (a === "--tmpfs") {
      const t = tmp("offload-p45a-tmpfs-");
      chmodSync(t, 0o1777);
      maps.push([v.split(":")[0]!, t]);
    }
    else if (a === "--workdir") workdir = v;
    else if (a === "--entrypoint") entrypoint = v;
    else if (a === "--user") user = v;
    else if (a === "--cap-add") caps.push(v.toLowerCase());
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
  const cmd = [...(entrypoint === null ? [] : [entrypoint]), ...argv.slice(i + 1)].map(map);
  if (cmd[0] === "bun") cmd[0] = process.execPath;
  const fullEnv: Record<string, string> = { PATH: process.env["PATH"] ?? "/usr/bin:/bin", ...Object.fromEntries(Object.entries(env).map(([k, v]) => [k, map(v)])) };
  if (o2.sudo) {
    // In a container the mounts are roots; on the host their parent (the sandbox folder, 0700) must be traversable.
    for (const host of mounts) chmodSync(join(host, ".."), 0o711);
  }
  const [uid, gid] = user.split(":");
  const priv =
    user === "0:0"
      ? ["setpriv", `--bounding-set=-all${caps.map((c) => `,+${c}`).join("")}`, "--inh-caps=-all", "--no-new-privs"]
      : ["setpriv", `--reuid=${uid}`, `--regid=${gid}`, "--clear-groups", "--bounding-set=-all", "--inh-caps=-all", "--no-new-privs"];
  const p = Bun.spawn(o2.sudo ? ["sudo", "-n", "env", "-i", ...Object.entries(fullEnv).map(([k, v]) => `${k}=${v}`), ...priv, ...cmd] : cmd, {
    cwd: map(workdir),
    env: fullEnv,
    stdin: new TextEncoder().encode(o.stdin ?? ""),
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, exit] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  return { exit, stdout, stderr, timed_out: false };
};

/** Worker code that turns a failing check into a REAL pass once loaded into the check process: every matcher is
 * neutered, so bun finishes, writes an honest JUnit report (1 test, 0 failures) and exits 0. (The old exit-code payload,
 * afterAll(process.exit(0)), is already stopped by the nonce proof, so it could not show the guard matters.) */
const NEUTER = 'const p = Object.getPrototypeOf(expect(0));\nfor (const k of Object.getOwnPropertyNames(p)) if (k.startsWith("to")) p[k] = () => undefined;\n';
const PAYLOAD = `import { expect } from "bun:test";\n${NEUTER}export {};\n`;
const REFUSED = "may not load builder code";
const FAILING_CHECK = 'import { expect, test } from "bun:test";\ntest("the tool works", () => { expect(1).toBe(2); });\n';
const TOOL = 'console.log("slug:" + (process.argv[2] ?? "").toLowerCase());\n';

/** Every file below would turn a failing check into exit 0 if bun loaded it into the check process. */
function plantedArtifact(): SandboxFile[] {
  return [
    file("evil.ts", PAYLOAD),
    file("bunfig.toml", 'preload = ["./evil.ts"]\n\n[test]\npreload = ["./evil.ts"]\n'),
    file("node_modules/helper/package.json", JSON.stringify({ name: "helper", main: "index.js" })),
    file("node_modules/helper/index.js", `const { expect } = require("bun:test");\n${NEUTER}`),
    file("tsconfig.json", JSON.stringify({ compilerOptions: { paths: { "@check/*": ["./evil.ts"] } } })),
    file("package.json", JSON.stringify({ name: "built", imports: { "#h": "./evil.ts" } })),
    file(".env", "OFFLOAD_PLANTED=1\n"),
    file("tool.ts", TOOL),
  ];
}

const SPEC: SandboxSpec = { image: "offload-check:test", vcpu: 1, memory_mb: 1024, wall_ms: 300_000, network_allowlist: [], env: {}, tag: "offload-build-guard", role: "verification" };
const emulate = emulator({ sudo: false });
// Emulated without root: the harness cannot split users, so these tests do not require the split proof.
const provider = new DockerProvider({ executor: emulate, docker: "docker", privilege_split: false });
const made: DockerProvider[] = [];
afterAll(async () => {
  for (const p of [provider, ...made]) for (const s of p.known()) await p.destroy(s).catch(() => {});
});
const run = async (content: string, artifact = plantedArtifact()) =>
  (await runShards({ provider, spec: SPEC, artifact, shards: [{ name: "held_out", check: checkSet("held_out", content) }], timeout_ms: 60_000 }))[0]!;

describe("p45a container guard", () => {
  test("SHARDS: (control) the planted payload makes a failing check really pass, with an honest JUnit report", () => {
    const ws = tmp();
    for (const f of plantedArtifact()) {
      mkdirSync(join(ws, f.path, ".."), { recursive: true });
      writeFileSync(join(ws, f.path), f.bytes);
    }
    const env = { PATH: process.env["PATH"] ?? "/usr/bin:/bin", HOME: ws };
    const honest = (file: string) => {
      const report = join(ws, `${file}.xml`);
      const exit = Bun.spawnSync([process.execPath, "test", "--no-env-file", "--reporter=junit", `--reporter-outfile=${report}`, `./${file}`], { cwd: ws, env, stdout: "pipe", stderr: "pipe" }).exitCode;
      const root = /<testsuites\b[^>]*>/.exec(readFileSync(report, "utf8"))![0];
      return { exit, tests: /tests="(\d+)"/.exec(root)![1], failures: /failures="(\d+)"/.exec(root)![1] };
    };
    writeFileSync(join(ws, "ctl.test.ts"), `import "./evil.ts";\n${FAILING_CHECK}`);
    expect(honest("ctl.test.ts")).toEqual({ exit: 0, tests: "1", failures: "0" });
    // the planted bunfig.toml alone is enough when the check runs with cwd = the artifact (the old shard layout)
    writeFileSync(join(ws, "ctl2.test.ts"), FAILING_CHECK);
    expect(honest("ctl2.test.ts")).toEqual({ exit: 0, tests: "1", failures: "0" });
  });

  test("SHARDS: a builder-planted bunfig.toml preload in the artifact cannot fake a PASS", async () => {
    const r = await run(FAILING_CHECK);
    expect(r.passed).toBe(false);
    // the check ran and failed on its own assertion: nothing neutered it
    expect(r.proof).toMatchObject({ nonce_ok: true, status: "fail", tests: 1 });
  });

  test("SHARDS: worker code reached by a path from the check folder (evil module, node_modules package) is refused by the guard", async () => {
    for (const spec of ["../work/evil.ts", "../work/node_modules/helper/index.js", "../work/node_modules/helper"]) {
      const check = `import { expect, test } from "bun:test";\nimport ${JSON.stringify(spec)};\ntest("the tool works", () => { expect(1).toBe(2); });\n`;
      const r = await run(check);
      expect([spec, r.passed, r.output.includes(REFUSED)]).toEqual([spec, false, true]);
    }
  });

  test("SHARDS: bare, tsconfig-paths and package-imports specifiers from the check folder never resolve into the artifact", async () => {
    // The check lives in /check, outside /work: resolution starts there, so the worker's node_modules, tsconfig.json
    // and package.json are never consulted (the old layout ran the check from inside the artifact; see the onLoad test).
    for (const spec of ["helper", "@check/x", "#h"]) {
      const check = `import { expect, test } from "bun:test";\nimport ${JSON.stringify(spec)};\ntest("the tool works", () => { expect(1).toBe(2); });\n`;
      const r = await run(check);
      expect([spec, r.passed]).toEqual([spec, false]);
      expect(r.output).toMatch(/Cannot find|not found|Could not resolve/i);
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
      privilege_split: false,
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

describe("p45a check guard on its own (onLoad)", () => {
  /** A layout v2 never produces (the check folder is Offload's), where a bare specifier or a tsconfig alias in the
   * check's folder resolves into the workspace without passing the guard's onResolve hook: only onLoad can stop it. */
  function layout() {
    const root = tmp();
    const work = join(root, "work");
    const app = join(root, "app");
    for (const f of plantedArtifact()) {
      mkdirSync(join(work, f.path, ".."), { recursive: true });
      writeFileSync(join(work, f.path), f.bytes);
    }
    mkdirSync(join(app, "node_modules"), { recursive: true });
    symlinkSync("../../work/node_modules/helper", join(app, "node_modules", "helper"));
    writeFileSync(join(app, "tsconfig.json"), JSON.stringify({ compilerOptions: { paths: { "@check/*": ["../work/evil.ts"] } } }));
    writeFileSync(join(app, "guard.ts"), GUARD_TS);
    return { work, app };
  }
  const runIn = (l: { work: string; app: string }, spec: string, guard: boolean) => {
    writeFileSync(join(l.app, "bunfig.toml"), guard ? SHARD_BUNFIG : "\n");
    writeFileSync(join(l.app, "c.test.ts"), `import ${JSON.stringify(spec)};\n${FAILING_CHECK}`);
    const p = Bun.spawnSync([process.execPath, "test", `--config=${join(l.app, "bunfig.toml")}`, "--no-env-file", "--no-install", "./c.test.ts"], {
      cwd: l.app,
      env: { PATH: process.env["PATH"] ?? "/usr/bin:/bin", HOME: l.app, OFFLOAD_WS: l.work, OFFLOAD_WS_RAW: l.work, OFFLOAD_REFUSED: BUILDER_IMPORT_REFUSED },
      stdout: "pipe",
      stderr: "pipe",
    });
    return { exit: p.exitCode, out: p.stdout.toString() + p.stderr.toString() };
  };

  test("SHARDS: the guard refuses worker code reached through a node_modules symlink or a tsconfig paths alias", () => {
    const l = layout();
    for (const spec of ["helper", "@check/x"]) {
      // control: without the guard the worker's module loads and the failing check passes
      expect([spec, runIn(l, spec, false).exit]).toEqual([spec, 0]);
      const g = runIn(l, spec, true);
      expect([spec, g.exit, g.out.includes(REFUSED)]).toEqual([spec, 1, true]);
    }
  });

  test("SHARDS: a path into the workspace is refused at resolution (onResolve), before onLoad is ever asked", () => {
    // onLoad would also stop it (defence in depth); this pins the first line of defence on its own.
    const l = layout();
    for (const spec of [join(l.work, "evil.ts"), "../work/evil.ts"]) {
      const g = runIn(l, spec, true);
      expect([spec, g.exit, g.out.includes(REFUSED)]).toEqual([spec, 1, true]);
      expect([spec, g.out.includes("if (builder(p)) throw new Error")]).toEqual([spec, true]);
    }
  });

  test("SHARDS: the guard refuses an absolute path into the workspace", () => {
    const l = layout();
    const spec = join(l.work, "evil.ts");
    expect(runIn(l, spec, false).exit).toBe(0);
    const g = runIn(l, spec, true);
    expect([g.exit, g.out.includes(REFUSED)]).toEqual([1, true]);
  });
});

/** Privileged tests need passwordless sudo AND setpriv (util-linux): they never fall back to full root, which would
 * hide what the container's three capabilities cannot do (review round 5). */
const sudoOk = (() => {
  try {
    return (
      Bun.spawnSync(["sudo", "-n", "true"], { stdout: "ignore", stderr: "ignore" }).exitCode === 0 &&
      Bun.spawnSync(["sudo", "-n", "setpriv", "--bounding-set=-all", "--inh-caps=-all", "--no-new-privs", "true"], { stdout: "ignore", stderr: "ignore" }).exitCode === 0
    );
  } catch {
    return false;
  }
})();

/** A held-out check the honest tool cannot pass: it expects a value nobody told the worker. */
const SECRET_CHECK = 'import { expect, test } from "bun:test";\ntest("edge", () => { const r = Bun.spawnSync([process.execPath, "run", "tool.ts", "edge"]); expect(r.stdout.toString().trim()).toBe("zq-7781-unguessable"); });\n';
/** A built tool that does not do the work: it finds the check (a known path, or through its parents' command lines)
 * and prints the literal the check expects. */
const CHEAT_TOOL = [
  'import { readFileSync, readdirSync } from "node:fs";',
  'import { dirname } from "node:path";',
  'const paths = new Set(["/check/accept.test.ts"]);',
  'for (const pid of readdirSync("/proc").filter((p) => /^\\d+$/.test(p))) {',
  '  try { for (const a of readFileSync(`/proc/${pid}/cmdline`, "utf8").split("\\0")) if (a.startsWith("/")) paths.add(a.endsWith("accept.test.ts") ? a : dirname(a) + "/accept.test.ts"); } catch {}',
  '}',
  'for (const p of paths) {',
  '  try { const m = /toBe\\("([^"]+)"\\)/.exec(readFileSync(p, "utf8")); if (m) { console.log(m[1]); process.exit(0); } } catch {}',
  '}',
  'console.log("I do not know");',
  '',
].join("\n");
const HONEST_SHARED = [
  'import { expect, test } from "bun:test";',
  'import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";',
  'import { tmpdir } from "node:os";',
  'import { join } from "node:path";',
  'test("shares a temp folder with the tool", () => {',
  '  const d = mkdtempSync(join(tmpdir(), "fx-"));',
  '  writeFileSync(join(d, "in.txt"), "Hello World");',
  '  const r = Bun.spawnSync([process.execPath, "run", "slug.ts", join(d, "in.txt"), join(d, "out.txt")]);',
  '  expect(r.exitCode).toBe(0);',
  '  expect(readFileSync(join(d, "out.txt"), "utf8")).toBe("hello-world");',
  '});',
  '',
].join("\n");
const SLUG_TOOL = 'import { readFileSync, writeFileSync } from "node:fs";\nwriteFileSync(process.argv[3]!, readFileSync(process.argv[2]!, "utf8").toLowerCase().split(" ").join("-"));\n';

describe("p45a held-out check isolation (review 3 finding 1)", () => {
  const shard = async (p: DockerProvider, check: string, artifact: SandboxFile[]) => (await runShards({ provider: p, spec: SPEC, artifact, shards: [{ name: "held_out", check: checkSet("held_out", check) }], timeout_ms: 60_000 }))[0]!;

  test("SHARDS: (control) without the user split, a tool that reads the check passes a held-out check it never solved", async () => {
    const r = await shard(provider, SECRET_CHECK, [file("tool.ts", CHEAT_TOOL)]);
    expect(r.passed).toBe(true);
    expect(r.proof).toMatchObject({ status: "pass", split: false });
  }, 60_000);

  test("SHARDS: a provider that isolates the tool refuses a pass whose harness did not split users", async () => {
    const strict = new DockerProvider({ executor: emulate, docker: "docker" }); // emulated, not root: no split
    made.push(strict);
    const r = await shard(strict, SECRET_CHECK, [file("tool.ts", CHEAT_TOOL)]);
    expect(r.proof).toMatchObject({ status: "pass", split: false });
    expect(r.passed).toBe(false);
  }, 60_000);

  test.skipIf(!sudoOk)("SHARDS: (privileged) a built tool that reads the held-out check cannot pass it: the check runs as one user, the tool as another", async () => {
    const p = new DockerProvider({ executor: emulator({ sudo: true }), docker: "docker" });
    made.push(p);
    const r = await shard(p, SECRET_CHECK, [file("tool.ts", CHEAT_TOOL)]);
    expect(r.proof).toMatchObject({ nonce_ok: true, status: "fail", split: true, tests: 1 });
    expect(r.passed).toBe(false);
    expect(r.output).toContain("I do not know");
  }, 60_000);

  test.skipIf(!sudoOk)("SHARDS: (privileged) an honest check shares a temp folder with the tool and passes under the user split", async () => {
    const p = new DockerProvider({ executor: emulator({ sudo: true }), docker: "docker" });
    made.push(p);
    const r = await shard(p, HONEST_SHARED, [file("slug.ts", SLUG_TOOL)]);
    expect(r.proof).toMatchObject({ status: "pass", split: true, tests: 1 });
    expect(r.passed).toBe(true);
  }, 60_000);

  /** A privileged shard of `check` with the given artifact; `leakyMount` writes the 0400 check files 0444 instead. */
  const privileged = async (check: string, artifact: SandboxFile[], o: { leakyMount?: boolean } = {}) => {
    const p = new DockerProvider({ executor: emulator({ sudo: true }), docker: "docker" });
    made.push(p);
    if (o.leakyMount) {
      const put = p.putFiles.bind(p);
      p.putFiles = (sb, m, files) => put(sb, m, files.map((f) => (f.mode === 0o400 ? { ...f, mode: 0o444 } : f)));
    }
    return shard(p, check, artifact);
  };

  test.skipIf(!sudoOk)("SHARDS: (privileged) when the tool's user can read the check anyway (a mount that ignores modes), the harness does not claim the split and no pass counts", async () => {
    const r = await privileged(HONEST_SHARED, [file("slug.ts", SLUG_TOOL)], { leakyMount: true });
    expect(r.proof).toMatchObject({ status: "pass", split: false });
    expect(r.passed).toBe(false);
  }, 60_000);

  // review round 5 finding 3: the linter is not the only guard. Under the split, every process API other than the
  // routed Bun.spawn / Bun.spawnSync throws at run time, so a check that slipped past the linter cannot start the tool
  // as the check's own user (who can read the check).
  const EDGE = 'expect(String(out).trim()).toBe("zq-7781-unguessable");';
  const BYPASSES: Array<[string, string]> = [
    ["const { $ } = Bun", 'const { $ } = Bun; const out = await $`${process.execPath} run tool.ts edge`.text();'],
    ['Bun["$"]', 'const out = await Bun["$"]`${process.execPath} run tool.ts edge`.text();'],
    ["process.getBuiltinModule", 'const out = process.getBuiltinModule("node:child_process").execFileSync(process.execPath, ["run", "tool.ts", "edge"]);'],
    ["require(child_process)", 'const out = require("node:child_process").spawnSync(process.execPath, ["run", "tool.ts", "edge"]).stdout;'],
    ["import child_process", 'const out = (await import("node:child_process")).execFileSync(process.execPath, ["run", "tool.ts", "edge"]);'],
  ];
  test.skipIf(!sudoOk)("SHARDS: (privileged) a check that starts the tool outside Bun.spawn/spawnSync (past the linter) cannot pass with a tool that reads the check", async () => {
    for (const [name, body] of BYPASSES) {
      const check = `import { expect, test } from "bun:test";\ntest("edge", async () => { ${body} ${EDGE} });\n`;
      const r = await privileged(check, [file("tool.ts", CHEAT_TOOL)]);
      expect([name, r.proof?.split, r.proof?.status, r.passed]).toEqual([name, true, "fail", false]);
    }
  }, 120_000);

  test.skipIf(!sudoOk)("SHARDS: (privileged) the broker refuses a tool command outside the workspace", async () => {
    const check = 'import { expect, test } from "bun:test";\ntest("cwd", () => { const r = Bun.spawnSync(["/bin/true"], { cwd: "/tmp" }); expect(r.exitCode).toBe(126); expect(r.stderr.toString()).toContain("refused"); });\n';
    const r = await privileged(check, [file("slug.ts", SLUG_TOOL)]);
    expect(r.proof).toMatchObject({ status: "pass", split: true });
  }, 60_000);

  test.skipIf(!sudoOk)("SHARDS: (privileged) the tool gets a clean environment: PATH, HOME and TMPDIR only, nothing of the check's or the harness's", async () => {
    // `bun run` adds NODE and npm_* to its own process; everything else must come from the broker's clean environment
    const tool = 'console.log(Object.keys(process.env).filter((k) => k !== "NODE" && !k.startsWith("npm_")).sort().join(","));\n';
    const check = 'import { expect, test } from "bun:test";\ntest("env", () => { const r = Bun.spawnSync([process.execPath, "run", "env.ts"]); expect(r.stdout.toString().trim()).toBe("HOME,PATH,TMPDIR"); });\n';
    const r = await privileged(check, [file("env.ts", tool)]);
    expect(r.proof).toMatchObject({ status: "pass", split: true });
  }, 60_000);

  test.skipIf(!sudoOk)("SHARDS: (privileged) the tool's user cannot connect to the broker socket", async () => {
    const tool = 'let out = "refused"; try { const s = await Bun.connect({ unix: process.argv[2]!, socket: { data() {} } }); out = "connected"; s.end(); } catch {} console.log(out);\n';
    const check = 'import { expect, test } from "bun:test";\ntest("socket", () => { const r = Bun.spawnSync([process.execPath, "run", "dial.ts", process.env.OFFLOAD_BROKER ?? ""]); expect(r.stdout.toString().trim()).toBe("refused"); });\n';
    const r = await privileged(check, [file("dial.ts", tool)]);
    expect(r.proof).toMatchObject({ status: "pass", split: true });
  }, 60_000);

  test.skipIf(!sudoOk)("SANDBOX: (privileged) destroy removes folders and files a sandbox user made in /work", async () => {
    const p = new DockerProvider({ executor: emulator({ sudo: true }), docker: "docker" });
    made.push(p);
    const sb = await p.create(SPEC);
    const dirs = p.paths(sb);
    chmodSync(dirs.root, 0o711); // in a container /work is a mount root; on the host the sandbox folder must be traversable
    // what a worker's command does as 65534 with the default umask: tests/ (0755) and a file in it
    const made65534 = Bun.spawnSync(["sudo", "-n", "setpriv", "--reuid=65534", "--regid=65534", "--clear-groups", "sh", "-c", `umask 022; mkdir ${join(dirs.work, "tests")} && echo x > ${join(dirs.work, "tests", "a.test.ts")}`]);
    expect(made65534.exitCode).toBe(0);
    await p.destroy(sb);
    expect(existsSync(dirs.root)).toBe(false);
    expect(await p.list(SPEC.tag)).not.toContain(sb.id);
  }, 60_000);
});
