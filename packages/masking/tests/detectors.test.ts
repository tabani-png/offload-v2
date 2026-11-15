import { expect, test } from "bun:test";
import { BUILTIN_EXCLUSIONS, matchExclusion, scanForLeak, type ExclusionRule } from "../src/index.ts";

// Secret-shaped strings are assembled at run time so no literal in the repo looks like a credential.
const key = (prefix: string, n: number) => prefix + "aB3".repeat(Math.ceil(n / 3)).slice(0, n);

test("detectors: each rule names itself and stops at the first", () => {
  expect(scanForLeak("mail dana@example.test")).toBe("email");
  expect(scanForLeak("card 4111 1111 1111 1111")).toBe("card");
  expect(scanForLeak("iban GB82 WEST 1234 5698 7654 32")).toBe("iban");
  expect(scanForLeak(key("sk-ant-api03-", 40))).toBe("key");
  expect(scanForLeak("https://example.test/a/b")).toBe("url");
  expect(scanForLeak("call +14155550132")).toBe("phone");
  expect(scanForLeak("nothing to see here, 12 apps in 3 windows")).toBeNull();
});

test("detectors: card numbers need a valid Luhn sum and 13 to 19 digits", () => {
  for (const ok of ["4111111111111111", "4111 1111 1111 1111", "5500-0000-0000-0004", "378282246310005", "6011111111111117"]) {
    expect({ ok, hit: scanForLeak(`n ${ok} n`) }).toEqual({ ok, hit: "card" });
  }
  for (const no of ["4111111111111112", "1234567890123", "411111111111"]) {
    expect({ no, hit: scanForLeak(`n ${no} n`) }).toEqual({ no, hit: null });
  }
});

test("detectors: IBAN needs a valid mod-97 checksum", () => {
  for (const ok of ["GB82WEST12345698765432", "GB82 WEST 1234 5698 7654 32", "DE89 3704 0044 0532 0130 00", "FR1420041010050500013M02606"]) {
    expect({ ok, hit: scanForLeak(`pay ${ok} now`) }).toEqual({ ok, hit: "iban" });
  }
  expect(scanForLeak("pay GB82WEST12345698765433 now")).toBeNull();
  expect(scanForLeak("pay GB82 WEST 1234 5698 7654 32 PLEASE")).toBe("iban");
});

test("detectors: API keys and tokens", () => {
  const hits = [
    key("sk-ant-", 40), key("sk-", 32), key("ghp_", 36), key("gho_", 36), key("ghs_", 36), key("github_pat_", 40),
    "AKIA" + "ABCDEFGHIJKLMNOP", "ASIA" + "ABCDEFGHIJKLMNOP", key("xoxb-", 24), key("xoxp-", 24),
    "eyJhbGciOiJF.eyJzdWIiOiIx.c2lnbmF0dXJl", "-----BEGIN " + "RSA PRIVATE KEY-----", "Bearer " + "abcdef0123456789ABCDEF",
  ];
  for (const k of hits) expect({ k: k.slice(0, 8), hit: scanForLeak(`x ${k} y`) }).toEqual({ k: k.slice(0, 8), hit: "key" });
  for (const no of ["the skill and the risk", "sk-short", "a Bearer market", "ghp_short", "AKIA short"]) {
    expect({ no, hit: scanForLeak(no) }).toEqual({ no, hit: null });
  }
});

test("detectors: URLs leak only with a path, query or fragment", () => {
  for (const u of ["https://a.test/x", "http://a.test/?q=1", "https://a.test#frag", "ftp://a.test/f.txt"]) expect({ u, hit: scanForLeak(u) }).toEqual({ u, hit: "url" });
  for (const u of ["https://a.test", "https://a.test/", "see a.test for details"]) expect({ u, hit: scanForLeak(u) }).toEqual({ u, hit: null });
});

test("detectors: phone numbers (E.164 or 10 to 15 digits with separators), not dates or counts", () => {
  for (const p of ["+14155550132", "+44 20 7946 0958", "(415) 555-0132", "415-555-0132", "415.555.0132", "415 555 0132"]) {
    expect({ p, hit: scanForLeak(`call ${p} now`) }).toEqual({ p, hit: "phone" });
  }
  for (const n of ["2026-11-14 10:30", "2026-11-14 2026-11-15", "1,250,000 units", "12 apps", "version 3.12.4", "1731574800"]) {
    expect({ n, hit: scanForLeak(n) }).toEqual({ n, hit: null });
  }
});

test("detectors: pseudonyms and router placeholders are skipped before scanning", () => {
  const ok = [
    "<person:h_0123456789abcdef> wrote to <email:h_0123456789abcdef>", "<phone:h_0123456789abcdef>", "<doc:h_0123456789abcdef>",
    "<person:qkzt.1> <person:qkzt.2.first> <person:qkzt.me>",
  ];
  for (const t of ok) expect({ t, hit: scanForLeak(t) }).toEqual({ t, hit: null });
  // Only the token is skipped, not the text next to it.
  expect(scanForLeak("<person:h_0123456789abcdef> dana@example.test")).toBe("email");
});

test("exclusions: host exact or dot-suffix, bundle_id exact, title_contains case-insensitive", () => {
  const rules: ExclusionRule[] = [
    { kind: "host", value: "bank.example" }, { kind: "bundle_id", value: "com.example.vault" }, { kind: "title_contains", value: "Payroll" },
  ];
  expect(matchExclusion(rules, { host: "bank.example" })).toEqual(rules[0]!);
  expect(matchExclusion(rules, { host: "www.bank.example" })).toEqual(rules[0]!);
  expect(matchExclusion(rules, { host: "WWW.BANK.EXAMPLE" })).toEqual(rules[0]!);
  expect(matchExclusion(rules, { host: "notbank.example" })).toBeNull();
  expect(matchExclusion(rules, { host: "bank.example.evil.test" })).toBeNull();
  expect(matchExclusion(rules, { app_bundle_id: "com.example.vault" })).toEqual(rules[1]!);
  expect(matchExclusion(rules, { app_bundle_id: "com.example.vault2" })).toBeNull();
  expect(matchExclusion(rules, { title: "Q3 payroll run" })).toEqual(rules[2]!);
  expect(matchExclusion(rules, { title: "Pay roll" })).toBeNull();
  expect(matchExclusion(rules, {})).toBeNull();
});

test("exclusions: the builtin list is well formed and covers each kind", () => {
  expect(BUILTIN_EXCLUSIONS.length).toBeGreaterThan(10);
  for (const e of BUILTIN_EXCLUSIONS) {
    expect(["bundle_id", "host", "title_contains"]).toContain(e.kind);
    expect(e.value.length).toBeGreaterThan(0);
    if (e.kind === "host") expect(e.value).toMatch(/^[a-z0-9.-]+$/);
  }
  expect(new Set(BUILTIN_EXCLUSIONS.map((e) => e.kind))).toEqual(new Set(["bundle_id", "host", "title_contains"]));
  expect(new Set(BUILTIN_EXCLUSIONS.map((e) => `${e.kind}:${e.value}`)).size).toBe(BUILTIN_EXCLUSIONS.length);
});
