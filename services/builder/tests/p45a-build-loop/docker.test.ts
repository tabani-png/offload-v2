// The Docker SandboxProvider (self-host, dev; ADR 0011), from old container.ts's flags: no network, read-only root,
// every capability dropped, the check folder mounted read-only, one sandbox per shard, temps removed. Hardened beyond
// the old runner: non-root user, no-new-privileges, pids limit, env allowlist, a timed-out container is removed.
// The executor is faked to pin the exact argv; a LIVE: test runs real Docker and skips when it is absent.
import { afterAll, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { DockerProvider, spawnExecutor, type Executor } from "../../src/sandbox/docker.ts";
import { HARNESS_TS } from "../../src/harness.ts";
import { cloudProvider, sandboxProviderFromEnv } from "../../src/sandbox/cloud.ts";
import { SandboxInfraError, type SandboxSpec } from "../../src/sandbox/provider.ts";
import { runShards } from "../../src/shards.ts";
import { checkSet, file, text } from "./setup.ts";

const SPEC: SandboxSpec = { image: "offload-check@sha256:" + "a".repeat(64), vcpu: 1, memory_mb: 1024, wall_ms: 300_000, network_allowlist: [], env: {}, tag: "offload-build-b1", role: "verification" };
const made: DockerProvider[] = [];
function fake(reply: (argv: string[]) => { exit: number | null; stdout?: string; timed_out?: boolean } | "throw" = () => ({ exit: 0 })) {
  const calls: Array<{ argv: string[]; stdin: string | undefined }> = [];
  const executor: Executor = async (argv, o) => {
    calls.push({ argv, stdin: o.stdin });
    const r = reply(argv);
    if (r === "throw") throw new Error("spawn docker ENOENT");
    return { exit: r.exit, stdout: r.stdout ?? "", stderr: "", timed_out: r.timed_out ?? false };
  };
  const p = new DockerProvider({ executor, docker: "/usr/bin/docker" });
  made.push(p);
  return { p, calls };
}
afterAll(async () => {
  for (const p of made) for (const s of p.known()) await p.destroy(s).catch(() => {});
});

describe("p45a docker provider", () => {
  test("SANDBOX: the docker argv is exact: no network, read-only root, all caps dropped, non-root, the check folder read-only", async () => {
    const { p, calls } = fake();
    const sb = await p.create(SPEC);
    const dirs = p.paths(sb);
    await p.exec(sb, { argv: ["bun", "/check/harness.ts"], cwd: "/check", stdin: "nonce\n", env: { OFFLOAD_WS: "/work", OFFLOAD_CHECK_DIR: "/check" }, timeout_ms: 1000, harness: true });
    const a = calls[0]!.argv;
    const name = a[a.indexOf("--name") + 1]!;
    const uid = process.getuid!();
    const gid = process.getgid!();
    const tool = uid === 65534 ? 65533 : 65534;
    expect(a).toEqual([
      "/usr/bin/docker", "run", "--rm", "-i",
      "--name", name,
      "--label", `offload.sandbox=${sb.id}`,
      "--label", "offload.tag=offload-build-b1",
      "--network", "none",
      // the image must already be on the host (prebuilt, pinned): never fetched at check time
      "--pull", "never",
      "--read-only",
      "--cap-drop", "ALL",
      "--security-opt", "no-new-privileges",
      "--pids-limit", "256",
      "--memory", "1024m",
      "--cpus", "1",
      // the harness starts as root with only what it needs to run the check and the tool as two other users
      "--user", "0:0",
      "--cap-add", "CHOWN",
      "--cap-add", "SETGID",
      "--cap-add", "SETUID",
      "--tmpfs", "/tmp:rw,nosuid,nodev,size=64m",
      "--env", "HOME=/tmp",
      "--env", "TMPDIR=/tmp",
      "--env", `OFFLOAD_CHECK_UID=${uid}`,
      "--env", `OFFLOAD_CHECK_GID=${gid}`,
      "--env", `OFFLOAD_TOOL_UID=${tool}`,
      "--env", "OFFLOAD_CHECK_DIR=/check",
      "--env", "OFFLOAD_WS=/work",
      "--mount", `type=bind,source=${dirs.work},target=/work`,
      "--mount", `type=bind,source=${dirs.check},target=/check,readonly`,
      "--workdir", "/check",
      // the image's own entrypoint is never used: the harness must be PID 1 for its kill(-1) sweep
      "--entrypoint", "bun",
      SPEC.image,
      "/check/harness.ts",
    ]);
    expect(name).toMatch(/^offload-sbx_[0-9a-f]+-\d+$/);
    expect(calls[0]!.stdin).toBe("nonce\n");
    expect(a.join(" ")).not.toContain("nonce");
  });

  test("SANDBOX: on a split provider only the trusted harness runs as root; any other exec (a worker's command) runs as nobody with no added capability", async () => {
    const { p, calls } = fake();
    for (const role of ["worker", "verification"] as const) {
      const sb = await p.create({ ...SPEC, role });
      await p.exec(sb, { argv: ["bun", "-e", "1"], cwd: "/work", timeout_ms: 10 });
      const a = calls.at(-1)!.argv;
      expect(a[a.indexOf("--user") + 1]).toBe("65534:65534");
      expect(a).not.toContain("--cap-add");
      expect(a.join(" ")).not.toContain("OFFLOAD_CHECK_UID");
      expect(a.join(" ")).not.toContain("OFFLOAD_TOOL_UID");
      expect(a).toContain("--cap-drop");
      await p.exec(sb, { argv: ["bun", "/check/harness.ts"], cwd: "/check", timeout_ms: 10, harness: true });
      const h = calls.at(-1)!.argv;
      expect(h[h.indexOf("--user") + 1]).toBe("0:0");
      expect(h.filter((_x, k) => h[k - 1] === "--cap-add")).toEqual(["CHOWN", "SETGID", "SETUID"]);
    }
  });

  test("SANDBOX: destroy forgets a sandbox even when its folder cannot be removed (the reaper takes it from there)", async () => {
    const { p } = fake();
    const sb = await p.create(SPEC);
    const dirs = p.paths(sb);
    mkdirSync(join(dirs.work, "stuck"));
    writeFileSync(join(dirs.work, "stuck", "f"), "x");
    chmodSync(join(dirs.work, "stuck"), 0o555);
    try {
      await p.destroy(sb);
      expect(p.known().map((x) => x.id)).not.toContain(sb.id);
    } finally {
      chmodSync(join(dirs.work, "stuck"), 0o755);
      rmSync(dirs.root, { recursive: true, force: true });
    }
  });

  test("SANDBOX: without the user split (development only) the container runs as nobody with no added capability", async () => {
    const calls: string[][] = [];
    const p = new DockerProvider({ executor: async (argv) => (calls.push(argv), { exit: 0, stdout: "", stderr: "", timed_out: false }), docker: "docker", privilege_split: false });
    expect(p.isolates_tool).toBe(false);
    const sb = await p.create(SPEC);
    await p.exec(sb, { argv: ["bun", "/check/harness.ts"], cwd: "/check", timeout_ms: 10 });
    const a = calls[0]!.join(" ");
    expect(a).toContain("--user 65534:65534");
    expect(a).not.toContain("--cap-add");
    expect(a).not.toContain("OFFLOAD_CHECK_UID");
    await p.destroy(sb);
    expect(new DockerProvider({ executor: async () => ({ exit: 0, stdout: "", stderr: "", timed_out: false }) }).isolates_tool).toBe(true);
  });

  test("SANDBOX: check files keep the mode asked for: the check readable only by its user, the harness by all", async () => {
    const { p } = fake();
    const sb = await p.create(SPEC);
    await p.putFiles(sb, "check", [{ ...file("accept.test.ts", "// secret\n"), mode: 0o400 }, file("harness.ts", "// h\n")]);
    const dirs = p.paths(sb);
    expect(statSync(join(dirs.check, "accept.test.ts")).mode & 0o777).toBe(0o400);
    expect(statSync(join(dirs.check, "harness.ts")).mode & 0o777).toBe(0o444);
  });

  test("SANDBOX: a timed-out exec is a failed shard and its container is removed", async () => {
    const { p, calls } = fake((argv) => (argv[1] === "run" ? { exit: null, timed_out: true } : { exit: 0 }));
    const r = await runShards({ provider: p, spec: SPEC, artifact: [file("slug.ts", "x")], shards: [{ name: "frozen", check: checkSet("frozen", "// FROZEN\n") }], timeout_ms: 50 });
    expect(r[0]).toMatchObject({ passed: false, exit: null });
    const run = calls.find((c) => c.argv[1] === "run")!.argv;
    const name = run[run.indexOf("--name") + 1]!;
    expect(calls.some((c) => c.argv.join(" ") === `/usr/bin/docker rm -f ${name}`)).toBe(true);
  });

  test("SANDBOX: an exec error is a failed shard, never a pass", async () => {
    const { p } = fake(() => "throw");
    const r = await runShards({ provider: p, spec: SPEC, artifact: [file("slug.ts", "x")], shards: [{ name: "frozen", check: checkSet("frozen", "// FROZEN\n") }], timeout_ms: 50 });
    expect(r[0]).toMatchObject({ passed: false, exit: null });
  });

  test("SANDBOX: a docker failure that is not a check result (exit 125 to 127, CLI not runnable) is an infra error, never a check failure", async () => {
    for (const reply of [{ exit: 125 }, { exit: 126 }, { exit: 127 }, "throw" as const]) {
      const { p } = fake((argv) => (argv[1] === "run" ? reply : { exit: 0 }));
      const sb = await p.create(SPEC);
      await expect(p.exec(sb, { argv: ["bun", "/check/harness.ts"], cwd: "/check", timeout_ms: 50 })).rejects.toBeInstanceOf(SandboxInfraError);
      const r = await runShards({ provider: p, spec: SPEC, artifact: [file("slug.ts", "x")], shards: [{ name: "frozen", check: checkSet("frozen", "// FROZEN\n") }], timeout_ms: 50 });
      expect(r[0]).toMatchObject({ passed: false, error: "infra" });
    }
    // a check that ran and failed is a check result, not infra
    const { p } = fake((argv) => (argv[1] === "run" ? { exit: 1 } : { exit: 0 }));
    const r = await runShards({ provider: p, spec: SPEC, artifact: [file("slug.ts", "x")], shards: [{ name: "frozen", check: checkSet("frozen", "// FROZEN\n") }], timeout_ms: 50 });
    expect(r[0]).toMatchObject({ passed: false, error: null });
  });

  test("SANDBOX: env names that look like credentials are refused; a network allowlist is refused until the egress proxy", async () => {
    const { p } = fake();
    for (const env of [{ ANTHROPIC_API_KEY: "x" }, { GITHUB_TOKEN: "x" }, { DATABASE_URL: "x" }, { AWS_SECRET_ACCESS_KEY: "x" }, { PATH: "/evil" }]) {
      await expect(p.create({ ...SPEC, env })).rejects.toThrow(/not allowed/);
      const sb = await p.create(SPEC);
      await expect(p.exec(sb, { argv: ["true"], cwd: "/work", env, timeout_ms: 10 })).rejects.toThrow(/not allowed/);
    }
    await expect(p.create({ ...SPEC, network_allowlist: ["proxy.internal:8443"] })).rejects.toThrow(/network/);
  });

  test("SANDBOX: files stay inside the sandbox folders; the check folder is read-only; symlinks are never followed out", async () => {
    const { p } = fake();
    const sb = await p.create(SPEC);
    await p.putFiles(sb, "work", [file("src/slug.ts", "// good\n")]);
    await p.putFiles(sb, "check", [file("accept.test.ts", "// FROZEN\n")]);
    for (const bad of ["../check/accept.test.ts", "/etc/x", "a/../../b"]) await expect(p.putFiles(sb, "work", [file(bad, "evil")])).rejects.toThrow(/escapes/);
    const dirs = p.paths(sb);
    expect(readFileSync(join(dirs.check, "accept.test.ts"), "utf8")).toBe("// FROZEN\n");
    if (process.getuid?.() !== 0) expect(() => writeFileSync(join(dirs.check, "accept.test.ts"), "x")).toThrow();
    symlinkSync("/etc/hostname", join(dirs.work, "link"));
    mkdirSync(join(dirs.work, "deep"), { recursive: true });
    const got = await p.getFiles(sb, "work");
    expect(got.map((f) => f.path)).toEqual(["src/slug.ts"]);
    expect(text(got[0])).toBe("// good\n");
    const before = await p.snapshot(sb, "work");
    await p.putFiles(sb, "work", [file("new.txt", "x")]);
    expect(await p.snapshot(sb, "work")).not.toBe(before);
  });

  test("SANDBOX: the workspace snapshot sees an empty folder or a symlink a check created (teeth gate)", async () => {
    const { p } = fake();
    const sb = await p.create(SPEC);
    const dirs = p.paths(sb);
    const s0 = await p.snapshot(sb, "work");
    mkdirSync(join(dirs.work, "made-by-check"));
    const s1 = await p.snapshot(sb, "work");
    expect(s1).not.toBe(s0);
    symlinkSync("/etc/hostname", join(dirs.work, "link-by-check"));
    const s2 = await p.snapshot(sb, "work");
    expect(s2).not.toBe(s1);
    // and the artifact itself still never carries the symlink or the empty folder
    expect((await p.getFiles(sb, "work")).map((f) => f.path)).toEqual([]);
  });

  test("SANDBOX: destroy removes the sandbox's temp folders and its containers; list finds sandboxes by tag", async () => {
    const { p, calls } = fake((argv) => (argv[1] === "ps" ? { exit: 0, stdout: "c0ffee\nbeef01\n" } : { exit: 0 }));
    const sb = await p.create(SPEC);
    const dirs = p.paths(sb);
    expect(existsSync(dirs.work)).toBe(true);
    expect(await p.list("offload-build-b1")).toContain(sb.id);
    await p.destroy(sb);
    expect(existsSync(dirs.root)).toBe(false);
    expect(calls.some((c) => c.argv.join(" ") === `/usr/bin/docker ps -aq --filter label=offload.sandbox=${sb.id}`)).toBe(true);
    expect(calls.some((c) => c.argv.join(" ") === "/usr/bin/docker rm -f c0ffee beef01")).toBe(true);
  });

  test("SANDBOX: an artifact file over the size limit is refused, not copied into verification", async () => {
    const { p } = fake();
    const sb = await p.create(SPEC);
    writeFileSync(join(p.paths(sb).work, "huge.bin"), new Uint8Array(4 * 1024 * 1024 + 1));
    await expect(p.getFiles(sb, "work")).rejects.toThrow(/too large/);
  });

  test("SANDBOX: the docker CLI gets PATH and HOME only, never the builder's environment", async () => {
    const r = await spawnExecutor(["env"], { timeout_ms: 10_000 });
    const names = r.stdout.split("\n").filter((l) => l.includes("=")).map((l) => l.slice(0, l.indexOf("="))).sort();
    expect(names).toEqual(["HOME", "PATH"]);
  });

  test("SANDBOX: the harness runs bun test with --no-install, --no-env-file and the check folder's own bunfig", () => {
    for (const flag of ['"--no-install"', '"--no-env-file"', '"--config=" + join(CHECK, "bunfig.toml")']) expect(HARNESS_TS).toContain(flag);
  });

  test("SANDBOX: the provider is chosen by OFFLOAD_SANDBOX_PROVIDER; the cloud provider is a stub that fails as infra", async () => {
    expect(sandboxProviderFromEnv({}).name).toBe("docker");
    expect(sandboxProviderFromEnv({ OFFLOAD_SANDBOX_PROVIDER: "docker" }).name).toBe("docker");
    expect(sandboxProviderFromEnv({ OFFLOAD_SANDBOX_PROVIDER: "e2b" }).name).toBe("e2b");
    expect(() => sandboxProviderFromEnv({ OFFLOAD_SANDBOX_PROVIDER: "sandbox-exec" })).toThrow();
    expect(() => sandboxProviderFromEnv({ OFFLOAD_SANDBOX_PROVIDER: "apple-container" })).toThrow();
    await expect(cloudProvider().create(SPEC)).rejects.toBeInstanceOf(SandboxInfraError);
  });
});

const dockerUp = (() => {
  try {
    return Bun.spawnSync(["docker", "info"], { stdout: "ignore", stderr: "ignore", env: { PATH: process.env["PATH"] ?? "/usr/bin:/bin" } }).exitCode === 0;
  } catch {
    return false;
  }
})();

describe.skipIf(!dockerUp)("p45a docker provider (live)", () => {
  test("LIVE: a real shard passes an honest check, fails a failing one, and cannot reach the network", async () => {
    const p = new DockerProvider({ executor: spawnExecutor, docker: "docker" });
    made.push(p);
    const image = process.env["OFFLOAD_SANDBOX_IMAGE"] ?? "oven/bun:1.4.4";
    const spec = { ...SPEC, image };
    const honest = 'import { expect, test } from "bun:test";\ntest("slug", () => { const r = Bun.spawnSync([process.execPath, "run", "slug.ts", "A B"]); expect(r.stdout.toString().trim()).toBe("a-b"); });\n';
    const net = 'import { expect, test } from "bun:test";\ntest("no network, no registry", async () => { for (const u of ["http://1.1.1.1", "https://registry.npmjs.org/left-pad"]) { let ok = false; try { await fetch(u, { signal: AbortSignal.timeout(3000) }); ok = true; } catch {} expect(ok).toBe(false); } });\n';
    const failing = 'import { expect, test } from "bun:test";\ntest("x", () => { expect(1).toBe(2); });\n';
    const art = [file("slug.ts", 'console.log((process.argv[2] ?? "").toLowerCase().split(" ").join("-"));\n')];
    const r = await runShards({ provider: p, spec, artifact: art, shards: [{ name: "frozen", check: checkSet("frozen", honest) }, { name: "held_out", check: checkSet("held_out", net) }], timeout_ms: 120_000 });
    expect(r.map((x) => x.passed)).toEqual([true, true]);
    // the harness ran as PID 1 and swept every other process before reading the report
    expect(r.map((x) => x.proof?.swept)).toEqual([true, true]);
    const f = await runShards({ provider: p, spec, artifact: art, shards: [{ name: "frozen", check: checkSet("frozen", failing) }], timeout_ms: 120_000 });
    expect(f[0]!.passed).toBe(false);
    expect(r.map((x) => x.proof?.split)).toEqual([true, true]);
    // a tool that reads /check to learn the expected answer cannot (the check runs as another user)
    const secret = 'import { expect, test } from "bun:test";\ntest("edge", () => { const r = Bun.spawnSync([process.execPath, "run", "tool.ts"]); expect(r.stdout.toString().trim()).toBe("zq-7781-unguessable"); });\n';
    const cheat = 'let out = "I do not know"; try { const m = /toBe\\("([^"]+)"\\)/.exec(require("fs").readFileSync("/check/accept.test.ts", "utf8")); if (m) out = m[1]; } catch {} console.log(out);\n';
    const c = await runShards({ provider: p, spec, artifact: [file("tool.ts", cheat)], shards: [{ name: "held_out", check: checkSet("held_out", secret) }], timeout_ms: 120_000 });
    expect(c[0]!.passed).toBe(false);
  }, 300_000);
});
