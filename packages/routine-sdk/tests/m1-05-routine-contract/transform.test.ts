import { expect, test } from "bun:test";
import { loadTransform, runTransform, TransformError, type TransformErrorCode } from "../../src/transform.ts";

// Transforms arrive compiled to JavaScript: an ES module with `export default function (input) { ... }`.

async function expectTransformError(run: Promise<unknown>, code: TransformErrorCode): Promise<TransformError> {
  let caught: unknown;
  try {
    await run;
  } catch (err) {
    caught = err;
  }
  expect(caught).toBeInstanceOf(TransformError);
  const err = caught as TransformError;
  expect(err.code).toBe(code);
  return err;
}

test("TRANSFORM: a pure transform maps input to output", async () => {
  const source = `
    export default function (input) {
      return {
        count: input.rows.length,
        names: input.rows.map((r) => r.name.toUpperCase()),
        total: input.rows.reduce((s, r) => s + r.amount, 0),
      };
    }
  `;
  const input = { rows: [{ name: "a", amount: 2 }, { name: "b", amount: 3 }] };
  expect(await runTransform(source, input)).toEqual({ count: 2, names: ["A", "B"], total: 5 });
  // Arrow default exports and scalar outputs work too.
  expect(await runTransform("export default (n) => n * 2;", 21)).toBe(42);
  expect(await runTransform("export default () => null;", {})).toBeNull();
});

test("TRANSFORM: fetch, require and timers are not defined inside the isolate", async () => {
  const names = [
    "fetch",
    "require",
    "setTimeout",
    "setInterval",
    "setImmediate",
    "clearTimeout",
    "queueMicrotask",
    "XMLHttpRequest",
    "WebSocket",
    "process",
    "Bun",
    "Deno",
    "std",
    "os",
    "console",
    "module",
    "exports",
    "__dirname",
    "importScripts",
  ];
  const source = `
    export default function (names) {
      const out = {};
      for (const n of names) out[n] = typeof globalThis[n];
      return out;
    }
  `;
  const types = (await runTransform(source, names)) as Record<string, string>;
  for (const n of names) expect({ name: n, type: types[n] }).toEqual({ name: n, type: "undefined" });

  // A bare call to fetch throws a ReferenceError inside the isolate.
  await expectTransformError(runTransform(`export default () => fetch("https://example.invalid");`, null), "transform_error");

  // No module loader: a static import fails to load.
  await expectTransformError(
    runTransform(`import fs from "fs";\nexport default () => typeof fs;`, null),
    "transform_invalid",
  );
  await expectTransformError(
    runTransform(`import { x } from "./other.js";\nexport default () => x;`, null),
    "transform_invalid",
  );
});

test("TRANSFORM: a transform over 1 second is stopped", async () => {
  const started = performance.now();
  await expectTransformError(runTransform("export default () => { while (true) {} };", null), "transform_timeout");
  const elapsed = performance.now() - started;
  // Stopped at the 1 s limit, not before it and not long after.
  expect(elapsed).toBeGreaterThanOrEqual(900);
  expect(elapsed).toBeLessThan(3000);
}, 10_000);

test("TRANSFORM: a transform over 64 MiB is stopped", async () => {
  const source = `
    export default function () {
      const keep = [];
      for (let i = 0; ; i++) keep.push(new Array(1 << 20).fill(i));
    }
  `;
  await expectTransformError(runTransform(source, null), "transform_memory");

  // Large flat strings too (s + s would only build ropes and hit the string length limit, not memory).
  const strings = `
    export default function () {
      const keep = [];
      for (let i = 0; ; i++) keep.push("x".repeat(1 << 20) + i);
    }
  `;
  await expectTransformError(runTransform(strings, null), "transform_memory");

  // Many 1 MiB buffers, each under the limit on its own, are still stopped once the total passes 64 MiB.
  const buffers = `
    export default function () {
      const keep = [];
      for (let i = 0; i < 200; i++) keep.push(new Uint8Array(1 << 20));
      return keep.length;
    }
  `;
  await expectTransformError(runTransform(buffers, null), "transform_memory");

  // The isolate is not left in a bad state: the next run works.
  expect(await runTransform("export default (n) => n + 1;", 1)).toBe(2);
}, 10_000);

test("TRANSFORM: a transform well under 64 MiB still runs", async () => {
  // About 16 MiB of numbers: the limit is not set far below 64 MiB.
  const source = `
    export default function () {
      const a = new Array(2 * 1024 * 1024).fill(1.5);
      return a.length;
    }
  `;
  expect(await runTransform(source, null)).toBe(2 * 1024 * 1024);
}, 10_000);

test("TRANSFORM: a transform that throws gives transform_error", async () => {
  await expectTransformError(
    runTransform(`export default () => { throw new Error("bad row"); };`, null),
    "transform_error",
  );
  await expectTransformError(runTransform(`export default (i) => i.missing.field;`, {}), "transform_error");
});

test("TRANSFORM: source with no default function export is rejected", async () => {
  await expectTransformError(runTransform(`export const f = () => 1;`, null), "transform_invalid");
  await expectTransformError(runTransform(`export default 42;`, null), "transform_invalid");
  await expectTransformError(runTransform(`export default function (`, null), "transform_invalid");
});

test("TRANSFORM: input and output must be JSON values", async () => {
  // Output that JSON cannot carry is rejected, not silently dropped.
  await expectTransformError(runTransform(`export default () => undefined;`, null), "transform_invalid");
  await expectTransformError(runTransform(`export default () => () => 1;`, null), "transform_invalid");
  // An async transform returns a promise, not a JSON value.
  await expectTransformError(runTransform(`export default async () => 1;`, null), "transform_invalid");
  await expectTransformError(
    runTransform(`export default () => { const o = {}; o.self = o; return o; };`, null),
    "transform_invalid",
  );
  // Input that JSON cannot carry is rejected before the isolate runs.
  await expectTransformError(runTransform(`export default (i) => i;`, { n: 1n }), "transform_invalid");
  await expectTransformError(runTransform(`export default (i) => i;`, { n: Number.NaN }), "transform_invalid");
  await expectTransformError(runTransform(`export default (i) => i;`, { n: undefined }), "transform_invalid");
  await expectTransformError(runTransform(`export default (i) => i;`, () => 1), "transform_invalid");
});

test("TRANSFORM: the transform gets a copy of the input and cannot change host data", async () => {
  const input = { rows: [{ n: 1 }] };
  const out = await runTransform(
    `export default (i) => { i.rows[0].n = 99; i.rows.push({ n: 2 }); return i; };`,
    input,
  );
  expect(out).toEqual({ rows: [{ n: 99 }, { n: 2 }] });
  expect(input).toEqual({ rows: [{ n: 1 }] });
});

test("TRANSFORM: each run gets a fresh isolate", async () => {
  const source = `export default () => { globalThis.runs = (globalThis.runs ?? 0) + 1; return globalThis.runs; };`;
  expect(await runTransform(source, null)).toBe(1);
  expect(await runTransform(source, null)).toBe(1);
});

test("TRANSFORM: loadTransform checks that a transform loads in the isolate", async () => {
  await loadTransform("export default (i) => i;");
  await expectTransformError(loadTransform("export const notDefault = 1;"), "transform_invalid");
  await expectTransformError(loadTransform(`import x from "net";\nexport default () => x;`), "transform_invalid");
  // Loading only evaluates the module body; a top-level infinite loop is still stopped.
  await expectTransformError(loadTransform("while (true) {}\nexport default () => 1;"), "transform_timeout");
}, 10_000);
