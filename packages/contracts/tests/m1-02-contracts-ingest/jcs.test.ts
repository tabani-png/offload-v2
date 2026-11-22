import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "bun:test";
import { jcs, sha256Hex } from "../../src/index.ts";

const DIR = join(import.meta.dir, "../fixtures/jcs");

test("JCS: canonical bytes match RFC 8785 test vectors", () => {
  const inputs = readdirSync(DIR).filter((f) => f.endsWith(".input.json")).sort();
  expect(inputs.length).toBeGreaterThanOrEqual(6);
  for (const f of inputs) {
    const name = f.replace(/\.input\.json$/, "");
    const input = JSON.parse(readFileSync(join(DIR, f), "utf8"));
    const expected = readFileSync(join(DIR, `${name}.output.json`));
    const got = Buffer.from(new TextEncoder().encode(jcs(input)));
    expect(got.equals(expected)).toBe(true);
  }
  // number serialisation from RFC 8785 section 3.2.2.3 and the ES6 table in the vectors' README
  expect(jcs([0, -0, 1e21, 1e-7, 9007199254740992, 0.000001, 333333333.33333329, 4.5, 2e-3])).toBe(
    "[0,0,1e+21,1e-7,9007199254740992,0.000001,333333333.3333333,4.5,0.002]",
  );
  expect(() => jcs(NaN)).toThrow();
  expect(() => jcs(Infinity)).toThrow();
  expect(() => jcs({ a: undefined })).toThrow();
  expect(() => jcs("\ud800")).toThrow();
  // eslint-disable-next-line no-sparse-arrays
  expect(() => jcs([, 1])).toThrow();
  expect(jcs("€$\u000f\nA'B\"\\\\\"/")).toBe('"€$\\u000f\\nA\'B\\"\\\\\\\\\\"/"');
});

test("JCS: object key order does not change the hash", () => {
  const a = { b: 1, a: [3, { y: 1, x: 2 }], c: "z" };
  const b = { c: "z", a: [3, { x: 2, y: 1 }], b: 1 };
  expect(jcs(a)).toBe('{"a":[3,{"x":2,"y":1}],"b":1,"c":"z"}');
  expect(jcs(a)).toBe(jcs(b));
  expect(sha256Hex(jcs(a))).toBe(sha256Hex(jcs(b)));
  // array order does matter
  expect(jcs([1, 2])).not.toBe(jcs([2, 1]));
  // keys sort by UTF-16 code units, not code points
  expect(jcs({ "\u{1F600}": 1, "￿": 2 })).toBe('{"\u{1F600}":1,"￿":2}');
});

test("JCS: sha256Hex of a known string matches a fixed vector", () => {
  expect(sha256Hex("abc")).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  expect(sha256Hex(new TextEncoder().encode("abc"))).toBe(sha256Hex("abc"));
  expect(sha256Hex("")).toBe("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  expect(sha256Hex("é")).toBe(sha256Hex(new Uint8Array([0xc3, 0xa9])));
});
