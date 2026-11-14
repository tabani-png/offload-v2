import { expect, test } from "bun:test";
import { ObservationSchema, PSEUDONYM_RE, isPseudonym } from "../../src/index.ts";
import { focus, obs, snapshot } from "./fixtures.ts";

const accepts = (o: unknown) => ObservationSchema.safeParse(o).success;
const title = (t: string) => accepts({ ...focus, title: t });
const text = (t: string) => accepts(snapshot(t));

test("PSEUDO: the four pseudonym kinds with 16 hex are accepted", () => {
  for (const kind of ["person", "email", "phone", "doc"]) {
    const p = `<${kind}:h_0123456789abcdef>`;
    expect(isPseudonym(p)).toBe(true);
    expect(PSEUDONYM_RE.test(p)).toBe(true);
    expect(title(`Re: ${p}`)).toBe(true);
    expect(text(`call ${p} then ${p}`)).toBe(true);
  }
  expect(accepts({ ...focus, doc: "<doc:h_ffffffffffffffff>" })).toBe(true);
  // the pseudonym is the whole value, not a substring
  expect(isPseudonym("x <doc:h_0123456789abcdef>")).toBe(false);
  expect(isPseudonym("<doc:h_0123456789abcdef> ")).toBe(false);
});

test("PSEUDO: a pseudonym with 15 hex, uppercase hex or an unknown kind is rejected", () => {
  const bad = [
    "<doc:h_0123456789abcde>", "<doc:h_0123456789abcdef0>", "<doc:h_0123456789ABCDEF>", "<doc:h_ABC0123456789def>",
    "<account:h_0123456789abcdef>", "<doc:0123456789abcdef>", "<Doc:h_0123456789abcdef>", "<doc:h_0123456789abcdeg>",
  ];
  for (const p of bad) {
    expect(isPseudonym(p)).toBe(false);
    expect(title(`Re: ${p}`)).toBe(false);
    expect(text(`see ${p}`)).toBe(false);
  }
  expect(accepts({ ...focus, doc: "<doc:h_ABC0123456789def>" })).toBe(false);
  expect(accepts({ ...focus, doc: "<account:h_0123456789abcdef>" })).toBe(false);
  expect(accepts({ ...focus, doc: "docs/finance" })).toBe(false);
});

test("PSEUDO: router placeholders are accepted and other angle tokens are rejected", () => {
  for (const t of ["<person:qkzt.1>", "<person:qkzt.1.first>", "<person:qkzt.me>", "<person:abcd.12.first> and <person:abcd.me>"]) {
    expect(title(t)).toBe(true);
    expect(text(t)).toBe(true);
  }
  for (const t of ["<secret:x>", "<email:qkzt.1>", "<person:QKZT.1>", "<person:qkz.1>", "<person:qkzt.1.last>", "<person:qkzt.>", "<card:4111>", "<url:https://example.com/a>"]) {
    expect(title(t)).toBe(false);
    expect(text(t)).toBe(false);
  }
  // a bad token anywhere in the string rejects it
  expect(text("fine <person:h_0123456789abcdef> but <secret:x> here")).toBe(false);
  // ordinary angle brackets are not tokens
  expect(text("if a < b and c > d then <b>bold</b> and x<y>")).toBe(true);
  // only title and text are scanned: other kinds have no free text
  expect(accepts(obs("pause", { reason: "user" }))).toBe(true);
});
