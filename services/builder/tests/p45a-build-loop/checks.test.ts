// CHECKS and HELDOUT (old checks.test intent + heldout.test.ts): check replies are TypeScript only, imports limited to
// builtins and relative files; the held-out check is written by a separate call that sees the brief and the visible
// check's interface, never its body; a copy is refused; it never appears in builder-facing text.
import { describe, expect, test } from "bun:test";
import { checkHash, disallowedTsImport, MAX_CHECK_BYTES, parseCheckReply, renderBuildMd } from "../../src/checks.ts";
import { HeldOutError, HELDOUT_WRITER_SYSTEM, sameCheck, writeHeldOut } from "../../src/heldout.ts";
import type { ModelPort, ModelRequest } from "../../src/model.ts";
import { BRIEF, checkSet, FROZEN_CONTENT, HELDOUT_CONTENT } from "./setup.ts";

const reply = (content: string, file = "accept.test.ts") => JSON.stringify({ file, content });
function fakeModel(answer: (r: ModelRequest) => string) {
  const calls: ModelRequest[] = [];
  const model: ModelPort = {
    async complete(r) {
      calls.push(r);
      return { text: answer(r), model: "claude-opus-5-5" };
    },
  };
  return { model, calls };
}
const visible = checkSet("frozen", FROZEN_CONTENT);

describe("p45a checks", () => {
  test("CHECKS: a check reply must be accept.test.ts with content under 32 KiB, no NUL, and only bun:/node: or relative imports", () => {
    expect(parseCheckReply(reply(FROZEN_CONTENT))).toEqual({ file: "accept.test.ts", content: FROZEN_CONTENT });
    expect(parseCheckReply("```json\n" + reply(FROZEN_CONTENT) + "\n```")).toEqual({ file: "accept.test.ts", content: FROZEN_CONTENT });
    for (const bad of [reply(FROZEN_CONTENT, "accept.py"), reply(""), reply("x".repeat(MAX_CHECK_BYTES + 1)), reply("a\u0000b"), "not json", "[]"]) {
      expect("reason" in parseCheckReply(bad)).toBe(true);
    }
    expect(checkHash(FROZEN_CONTENT)).toMatch(/^[0-9a-f]{64}$/);
  });

  test("CHECKS: a computed import or a bare package import is refused (it could resolve to a planted module)", () => {
    expect(disallowedTsImport('import { test } from "bun:test";\nimport { join } from "node:path";\nimport fs from "fs";\nimport "./helper.ts";')).toBeNull();
    expect(disallowedTsImport('import x from "helper";')).toBe('"helper"');
    expect(disallowedTsImport('import x from "#h";')).toBe('"#h"');
    expect(disallowedTsImport('import x from "@check/x";')).toBe('"@check/x"');
    expect(disallowedTsImport("const m = await import(name);")).toBe("a computed import()/require()");
    expect(disallowedTsImport('const m = require("left-pad");')).toBe('"left-pad"');
    expect("reason" in parseCheckReply(reply('import x from "helper";\n'))).toBe(true);
  });

  test("CHECKS: a check may start the built tool only with Bun.spawn or Bun.spawnSync (the guard routes those to the tool's own user)", () => {
    const ok = 'import { expect, test } from "bun:test";\ntest("t", () => { Bun.spawnSync([process.execPath, "run", "t.ts"]); Bun.spawn(["true"]); });\n';
    expect(parseCheckReply(reply(ok))).toEqual({ file: "accept.test.ts", content: ok });
    for (const bad of [
      'import { execSync } from "node:child_process";',
      'import cp from "child_process";',
      'const cp = require("node:child_process");',
      'import { $ } from "bun";',
      "await Bun.$`ls`;",
      'import { dlopen } from "bun:ffi";',
      'import { Worker } from "node:worker_threads";',
      'const w = new Worker("./x.ts");',
      'process.dlopen(module, "x.node");',
      'import cluster from "node:cluster";',
    ]) {
      const r = parseCheckReply(reply(`${bad}\nimport { test } from "bun:test";\ntest("t", () => {});\n`));
      expect([bad, "reason" in r]).toEqual([bad, true]);
    }
  });

  test("HELDOUT: never shown in BUILD.md (the builder-facing text): neither its content nor its hash", () => {
    const held = checkSet("held_out", HELDOUT_CONTENT);
    const md = renderBuildMd(BRIEF, visible);
    expect(md).toContain(visible.hash);
    expect(md).toContain("lowercase");
    expect(md).not.toContain("SECRET-HELDOUT-MARKER");
    expect(md).not.toContain(held.hash);
    expect(md.toLowerCase()).not.toContain("held-out");
    expect(md.toLowerCase()).not.toContain("held_out");
  });
});

describe("p45a held-out writer", () => {
  test("HELDOUT: a separate call on the check_write route writes it, with its sha256", async () => {
    const { model, calls } = fakeModel(() => reply(HELDOUT_CONTENT));
    const h = await writeHeldOut({ brief: BRIEF, visible, model });
    expect(calls).toHaveLength(1);
    expect(calls[0]!.route).toBe("check_write");
    expect(calls[0]!.system).toBe(HELDOUT_WRITER_SYSTEM);
    expect(h).toMatchObject({ kind: "held_out", file: "accept.test.ts", content: HELDOUT_CONTENT, hash: checkHash(HELDOUT_CONTENT), writer_model: "claude-opus-5-5" });
    expect(h.interface).toEqual(visible.interface);
  });

  test("HELDOUT: the writer sees the brief and the visible check's interface only, never the visible check's body", async () => {
    const { model, calls } = fakeModel(() => reply(HELDOUT_CONTENT));
    await writeHeldOut({ brief: BRIEF, visible, model });
    const sent = calls[0]!.system + calls[0]!.prompt;
    expect(sent).toContain("spaces become single dashes");
    expect(sent).toContain("bun run slug.ts <title>");
    expect(sent).toContain("the slug on one line");
    expect(sent).not.toContain("FROZEN slug check");
    expect(sent).not.toContain(visible.hash);
    expect(HELDOUT_WRITER_SYSTEM).toMatch(/different fixtures/i);
    expect(HELDOUT_WRITER_SYSTEM).toMatch(/boundar/i);
  });

  test("HELDOUT: a copy of the visible check is refused (not independent), even with comments or whitespace changed; so is a bad reply", async () => {
    const copies = [FROZEN_CONTENT, `// my own check\n${FROZEN_CONTENT.replace(/\n/g, "\n\n  ")}`, FROZEN_CONTENT.replace("// FROZEN slug check", "/* held */")];
    for (const c of copies) {
      expect(sameCheck(c, FROZEN_CONTENT)).toBe(true);
      const { model } = fakeModel(() => reply(c));
      const e = await writeHeldOut({ brief: BRIEF, visible, model }).catch((x) => x);
      expect(e).toBeInstanceOf(HeldOutError);
      expect((e as HeldOutError).message).toContain("copy of the visible check");
    }
    expect(sameCheck(HELDOUT_CONTENT, FROZEN_CONTENT)).toBe(false);
    for (const bad of ["no json", reply('import x from "helper";\n'), reply("")]) {
      const { model } = fakeModel(() => bad);
      expect(await writeHeldOut({ brief: BRIEF, visible, model }).catch((x) => x)).toBeInstanceOf(HeldOutError);
    }
  });

  test("HELDOUT: needs the visible check's interface first", async () => {
    const { model, calls } = fakeModel(() => reply(HELDOUT_CONTENT));
    const e = await writeHeldOut({ brief: BRIEF, visible: null, model }).catch((x) => x);
    expect(e).toBeInstanceOf(HeldOutError);
    expect(calls).toHaveLength(0);
  });
});
