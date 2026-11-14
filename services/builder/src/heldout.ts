// The held-out check (old builder/heldout.ts, rewritten). The Offload bench found the visible check mostly proves "it
// matched the interface": 10 of 42 builds that passed it failed an independent check. So a separate call (route
// check_write, fresh context, a different prompt) writes a second check from the brief and the visible check's
// INTERFACE only. Old heldout.ts sent the whole visible check, which made copies easy; ADR 0012 says the held-out
// writer never sees the check set. A copy of the visible check (ignoring comments and whitespace) is refused.
// Retries and repairs write a new one (ADR 0029); the design spend is the brain's, not the build cap.
import { checkHash, parseCheckReply, type Brief, type CheckInterface, type CheckSet } from "./checks.ts";
import type { ModelPort } from "./model.ts";

export class HeldOutError extends Error {}

export const HELDOUT_WRITER_SYSTEM = [
  "You write an acceptance check for a small tool before anyone builds it. The check decides done, not the builder.",
  "This check is held out: the builder never sees it. It must keep exactly the interface given (same file name, same commands, same output format), so a correct build passes it.",
  "Use different fixtures from any example in the brief, and test the boundaries the brief implies: empty and very long inputs, exact limits (at, one below, one above), repeated items, unusual characters, and anything the brief says must never happen.",
  "Write one file, accept.test.ts, for bun test. Import only bun:test and node: builtins. Run the built tool as a subprocess from the workspace root (Bun.spawnSync([process.execPath, 'run', ...])); never import the built code. No network. Put fixtures and outputs in a temporary folder, never in the workspace.",
  'Reply with JSON only: {"file":"accept.test.ts","content":"..."}.',
].join("\n");

/** Same check, ignoring comments and whitespace. */
export function sameCheck(a: string, b: string): boolean {
  const norm = (s: string) =>
    s
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .replace(/(^|[^:"'`])\/\/[^\n]*/g, "$1")
      .replace(/\s+/g, "");
  return norm(a) === norm(b);
}

export async function writeHeldOut(o: { brief: Brief; visible: CheckSet | null; model: ModelPort }): Promise<CheckSet> {
  if (o.visible === null) throw new HeldOutError("write the visible check (and its interface) before the held-out check");
  const iface: CheckInterface = o.visible.interface;
  const b = o.brief;
  const prompt = [
    "<brief>",
    `title: ${b.title}`,
    "inputs:",
    ...b.inputs.map((x) => `- ${x}`),
    "outputs:",
    ...b.outputs.map((x) => `- ${x}`),
    "acceptance:",
    ...b.acceptance.map((x) => `- ${x}`),
    "</brief>",
    "<interface>",
    `file: ${iface.file}`,
    "runs:",
    ...iface.entry.map((x) => `- ${x}`),
    `output: ${iface.output}`,
    "</interface>",
  ].join("\n");
  const reply = await o.model.complete({ route: "check_write", system: HELDOUT_WRITER_SYSTEM, prompt, max_tokens: 6000 });
  const parsed = parseCheckReply(reply.text);
  if ("reason" in parsed) throw new HeldOutError(`held-out check refused: ${parsed.reason}`);
  if (sameCheck(parsed.content, o.visible.content) || checkHash(parsed.content) === o.visible.hash) throw new HeldOutError("held-out check refused: it is a copy of the visible check");
  return { kind: "held_out", file: parsed.file, content: parsed.content, hash: checkHash(parsed.content), interface: iface, writer_model: reply.model };
}
