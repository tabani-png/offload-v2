/**
 * Transform isolate (spike S7, ADR 0026).
 *
 * A transform is compiled JavaScript: an ES module whose default export is `function (input) { return output }`.
 * Each call gets a fresh QuickJS WebAssembly instance with no host functions at all: no fetch, timers,
 * require, console or module loader. Input goes in as JSON text and output comes back as JSON text, so only
 * JSON values cross the boundary. Limits: 64 MiB memory, 1 s wall time.
 *
 * Memory: QuickJS's own malloc limit is not enough on its own. This build cannot measure allocation sizes
 * ("malloc_usable_size unavailable"), so it only stops single allocations over the limit; many 1 MiB buffers
 * pass it. The hard limit is the instance's WebAssembly.Memory, capped at 64 MiB in total (engine included).
 * The instance is thrown away after every call, so an out-of-memory run leaves no state behind.
 *
 * Privacy: errors carry the code and the isolate's error name only, never input, output or thrown messages.
 */
import { jcs } from "@offload/contracts";
import {
  newQuickJSWASMModuleFromVariant,
  newVariant,
  RELEASE_SYNC,
  shouldInterruptAfterDeadline,
  type QuickJSContext,
  type QuickJSHandle,
} from "quickjs-emscripten";

export const TRANSFORM_MEMORY_LIMIT_BYTES = 64 * 1024 * 1024;
export const TRANSFORM_TIME_LIMIT_MS = 1000;
const STACK_LIMIT_BYTES = 512 * 1024;
const WASM_PAGE_BYTES = 64 * 1024;
const WASM_INITIAL_PAGES = 256; // 16 MiB, enough for the engine to start

export type TransformErrorCode = "transform_timeout" | "transform_memory" | "transform_error" | "transform_invalid";

export class TransformError extends Error {
  readonly code: TransformErrorCode;
  constructor(code: TransformErrorCode, message: string) {
    super(message);
    this.name = "TransformError";
    this.code = code;
  }
}

/** Run a transform on `input` and return its output (a JSON value). Rejects with a TransformError. */
export async function runTransform(source: string, input: unknown): Promise<unknown> {
  let inputJson: string | undefined;
  try {
    inputJson = jcs(input); // strict: NaN, undefined, BigInt, cycles and non-plain objects throw
  } catch {
    inputJson = undefined;
  }
  if (typeof inputJson !== "string") throw new TransformError("transform_invalid", "transform input is not a JSON value");
  const json = inputJson;

  return withIsolate(source, ({ ctx, fn, fail, bridge }) => {
    const inputHandle = bridge("parse", ctx.newString(json), "transform_error");
    const result = ctx.callFunction(fn, ctx.undefined, inputHandle);
    inputHandle.dispose();
    if (result.error) throw fail(result.error, "transform_error", "transform threw");
    const settled = ctx.getPromiseState(result.value);
    // For a non-promise, getPromiseState returns the same handle with notAPromise set.
    if (!(settled.type === "fulfilled" && settled.notAPromise)) {
      // An async transform: its output would be a promise, which is not a JSON value.
      if (settled.type === "fulfilled") settled.value.dispose();
      if (settled.type === "rejected") settled.error.dispose();
      result.value.dispose();
      throw new TransformError("transform_invalid", "transform returned a promise");
    }
    const outText = bridge("stringify", result.value, "transform_invalid");
    const text = ctx.typeof(outText) === "string" ? ctx.getString(outText) : undefined;
    outText.dispose();
    if (text === undefined) throw new TransformError("transform_invalid", "transform output is not a JSON value");
    return JSON.parse(text) as unknown;
  });
}

/** Check that a transform loads in the isolate and has a default function export (deploy check, ADR 0026). */
export async function loadTransform(source: string): Promise<void> {
  await withIsolate(source, () => undefined);
}

type Fail = (err: QuickJSHandle, code: TransformErrorCode, what: string) => TransformError;
type Bridge = (name: "parse" | "stringify", arg: QuickJSHandle, code: TransformErrorCode) => QuickJSHandle;
interface Isolate {
  ctx: QuickJSContext;
  fn: QuickJSHandle;
  fail: Fail;
  bridge: Bridge;
}

// Captured before the module runs, so a transform that replaces JSON cannot change how input and output cross.
const BRIDGE_SOURCE = `({ parse: JSON.parse, stringify: JSON.stringify })`;

async function withIsolate<T>(source: string, body: (iso: Isolate) => T): Promise<T> {
  // A fresh instance per call with its memory capped: the hard memory limit and full isolation between runs.
  const wasmMemory = new WebAssembly.Memory({
    initial: WASM_INITIAL_PAGES,
    maximum: TRANSFORM_MEMORY_LIMIT_BYTES / WASM_PAGE_BYTES,
  });
  const qjs = await newQuickJSWASMModuleFromVariant(newVariant(RELEASE_SYNC, { wasmMemory }));
  const runtime = qjs.newRuntime();
  runtime.setMemoryLimit(TRANSFORM_MEMORY_LIMIT_BYTES);
  runtime.setMaxStackSize(STACK_LIMIT_BYTES);
  const pastDeadline = shouldInterruptAfterDeadline(Date.now() + TRANSFORM_TIME_LIMIT_MS);
  let timedOut = false;
  runtime.setInterruptHandler((rt) => (pastDeadline(rt) ? (timedOut = true) : false));
  // No module loader is installed, so any import fails to load.
  const ctx = runtime.newContext();
  const owned: QuickJSHandle[] = [];

  // Map an isolate error to a TransformError. Reads only the error's name and message and never logs them.
  const fail: Fail = (err, code, what) => {
    let name = "Error";
    let message = "";
    try {
      const d = ctx.dump(err) as { name?: unknown; message?: unknown } | null;
      if (d && typeof d === "object") {
        if (typeof d.name === "string") name = d.name;
        if (typeof d.message === "string") message = d.message;
      }
    } catch {
      message = "out of memory"; // dump itself can fail when the heap is exhausted
    } finally {
      if (err.alive) err.dispose();
    }
    if (timedOut) return new TransformError("transform_timeout", `transform exceeded ${TRANSFORM_TIME_LIMIT_MS} ms`);
    if (/out of memory|stack overflow/i.test(message)) {
      return new TransformError("transform_memory", "transform exceeded the memory limit");
    }
    return new TransformError(code, `${what} (${name})`);
  };

  try {
    const b = ctx.evalCode(BRIDGE_SOURCE, "bridge.js", { type: "global" });
    if (b.error) throw fail(b.error, "transform_error", "bridge failed");
    const bridgeObj = b.value;
    owned.push(bridgeObj);
    const bridge: Bridge = (name, arg, code) => {
      const f = ctx.getProp(bridgeObj, name);
      const r = ctx.callFunction(f, ctx.undefined, arg);
      f.dispose();
      arg.dispose();
      if (r.error) throw fail(r.error, code, `transform ${name} failed`);
      return r.value;
    };

    const loaded = ctx.evalCode(source, "transform.js", { type: "module" });
    if (loaded.error) throw fail(loaded.error, "transform_invalid", "transform did not load");
    owned.push(loaded.value);
    // Module evaluation may yield a promise for the exports; settle it with no host callbacks.
    let state = ctx.getPromiseState(loaded.value);
    if (state.type === "pending") {
      runtime.executePendingJobs();
      state = ctx.getPromiseState(loaded.value);
    }
    if (state.type === "pending") throw new TransformError("transform_invalid", "transform module did not settle");
    if (state.type === "rejected") throw fail(state.error, "transform_invalid", "transform did not load");
    const ns = state.value;
    if (ns !== loaded.value) owned.push(ns);
    const fn = ctx.getProp(ns, "default");
    owned.push(fn);
    if (ctx.typeof(fn) !== "function") {
      throw new TransformError("transform_invalid", "transform has no default function export");
    }
    return body({ ctx, fn, fail, bridge });
  } catch (err) {
    if (err instanceof TransformError) throw err;
    // A trap inside the WebAssembly instance (for example when its capped memory is exhausted).
    if (err instanceof WebAssembly.RuntimeError || (err instanceof Error && /memory|abort/i.test(err.message))) {
      throw new TransformError(timedOut ? "transform_timeout" : "transform_memory", "transform isolate failed");
    }
    throw err;
  } finally {
    // The instance is discarded either way; a failed cleanup after an out-of-memory run is not an error.
    try {
      for (const h of owned.reverse()) if (h.alive) h.dispose();
      ctx.dispose();
      runtime.dispose();
    } catch {
      // ignore
    }
  }
}
