import { readFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "bun:test";
import Ajv2020 from "ajv/dist/2020.js";
import {
  ErrorEnvelopeSchema,
  ERROR_CODES,
  ERROR_CODES_BY_STATUS,
  FigureSchema,
  IngestEnvelopeSchema,
  IngestReceiptSchema,
  KeyframeMetaSchema,
  NoticeAckSchema,
  ObservationSchema,
  RECEIPT_REJECTION_CODES,
  ReviewEventSchema,
  StepResultSchema,
  figureId,
  makeFigure,
  jcs,
  sha256Hex,
} from "../../src/index.ts";
import { generateSchemas } from "../../scripts/gen-json-schema.ts";
import {
  ULID_A, TS, envelope, focus, keyframeMeta, noticeAck, obs, reviewEvent, snapshot, stepResult, validByKind,
} from "./fixtures.ts";

const SCHEMA_DIR = join(import.meta.dir, "../../schemas");
const readSchema = (name: string): Record<string, unknown> =>
  JSON.parse(readFileSync(join(SCHEMA_DIR, `${name}.schema.json`), "utf8")) as Record<string, unknown>;
// Formats are covered by the patterns the generator emits; ajv runs strict on everything else.
const ajv = () => new Ajv2020({ strict: true, validateFormats: false });
const bothAccept = (name: string, zodSchema: { safeParse(v: unknown): { success: boolean } }, value: unknown) => {
  const validate = ajv().compile(readSchema(name));
  return { zod: zodSchema.safeParse(value).success, json: validate(value) as boolean };
};

test("CONTRACT: observation_batch round-trips zod ↔ JSON Schema 2020-12", () => {
  const good = envelope("observation_batch", Object.values(validByKind).map((o, i) => ({ ...o, id: `01JCZ3X5Q8M2N4P6R8T0V1W2${String(10 + i)}` })));
  expect(bothAccept("ingest-envelope", IngestEnvelopeSchema, good)).toEqual({ zod: true, json: true });
  const bad = envelope("observation_batch", [{ ...focus, ts: "yesterday" }]);
  expect(bothAccept("ingest-envelope", IngestEnvelopeSchema, bad)).toEqual({ zod: false, json: false });
  const badDevice = envelope("observation_batch", [focus], { device_id: "not-a-uuid" });
  expect(bothAccept("ingest-envelope", IngestEnvelopeSchema, badDevice)).toEqual({ zod: false, json: false });
});

test("CONTRACT: unknown fields on an observation are rejected", () => {
  const extra = { ...focus, window_text: "x" };
  expect(ObservationSchema.safeParse(extra).success).toBe(false);
  expect(bothAccept("observation", ObservationSchema, extra)).toEqual({ zod: false, json: false });
  expect(bothAccept("observation", ObservationSchema, focus)).toEqual({ zod: true, json: true });
  const env = envelope("observation_batch", [focus], { extra: 1 });
  expect(IngestEnvelopeSchema.safeParse(env).success).toBe(false);
  expect(ajv().compile(readSchema("ingest-envelope"))(env)).toBe(false);
});

test("CONTRACT: each observation kind enforces its required and allowed fields", () => {
  const accepts = (o: unknown) => bothAccept("observation", ObservationSchema, o);
  for (const [kind, ok] of Object.entries(validByKind)) {
    expect(accepts(ok)).toEqual({ zod: true, json: true });
    // a field that belongs to no kind but this one is never allowed on a different kind
    expect(accepts({ ...ok, bogus: 1 }).zod).toBe(false);
    expect(kind).toBe(ok["kind"] as string);
  }
  // required fields, one removal per kind
  const missing: [string, string][] = [
    ["focus", "app_bundle_id"], ["focus", "app_name"], ["input_counts", "keys"], ["input_counts", "clicks"],
    ["text_snapshot", "text"], ["text_snapshot", "text_hash"], ["text_snapshot", "text_source"],
    ["text_snapshot", "app_bundle_id"], ["pause", "reason"], ["resume", "reason"], ["permission_change", "perm"],
  ];
  for (const [kind, field] of missing) {
    const { [field]: _dropped, ...rest } = validByKind[kind]!;
    expect(accepts(rest)).toEqual({ zod: false, json: false });
  }
  // fields not listed for a kind are rejected
  expect(accepts(obs("idle_start", { app_bundle_id: "com.example.A" })).zod).toBe(false);
  expect(accepts(obs("idle_end", { reason: "user" })).zod).toBe(false);
  expect(accepts({ ...focus, text: "x" }).zod).toBe(false);
  expect(accepts({ ...validByKind["input_counts"], title: "x" }).zod).toBe(false);
  expect(accepts({ ...validByKind["text_snapshot"], app_name: "Mail" }).zod).toBe(false);
  expect(accepts({ ...validByKind["pause"], keys: 1 }).zod).toBe(false);
  // value ranges and enums
  expect(accepts(obs("input_counts", { keys: -1, clicks: 0 })).zod).toBe(false);
  expect(accepts(obs("input_counts", { keys: 100001, clicks: 0 })).zod).toBe(false);
  expect(accepts(obs("input_counts", { keys: 1.5, clicks: 0 })).zod).toBe(false);
  expect(accepts(obs("input_counts", { keys: 100000, clicks: 100000 }))).toEqual({ zod: true, json: true });
  expect(accepts(obs("pause", { reason: "boredom" })).zod).toBe(false);
  expect(accepts({ ...validByKind["text_snapshot"], text_source: "vision" }).zod).toBe(false);
  expect(accepts({ ...focus, title: "x".repeat(513) }).zod).toBe(false);
  expect(accepts({ ...focus, doc: "<person:h_0123456789abcdef>" }).zod).toBe(false);
  expect(accepts(obs("permission_change", { perm: { screen_recording: true } })).zod).toBe(false);
  // source and import_id are allowed on every kind; import needs an import_id
  const imp = "0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a44";
  for (const ok of Object.values(validByKind)) {
    expect(accepts({ ...ok, source: "import", import_id: imp }).zod).toBe(true);
    expect(accepts({ ...ok, source: "live" }).zod).toBe(true);
    expect(accepts({ ...ok, source: "import" }).zod).toBe(false);
  }
});

test("CONTRACT: text over 8000 characters is rejected", () => {
  const validate = ajv().compile(readSchema("observation"));
  const atLimit = snapshot("a".repeat(8000));
  const over = snapshot("a".repeat(8001));
  expect(ObservationSchema.safeParse(atLimit).success).toBe(true);
  expect(validate(atLimit)).toBe(true);
  expect(ObservationSchema.safeParse(over).success).toBe(false);
  expect(validate(over)).toBe(false);
});

test("CONTRACT: text_hash must equal sha256Hex(text)", () => {
  expect(ObservationSchema.safeParse(snapshot("hello")).success).toBe(true);
  const wrong = snapshot("hello", { text_hash: sha256Hex("hellO") });
  expect(ObservationSchema.safeParse(wrong).success).toBe(false);
  const upper = snapshot("hello", { text_hash: sha256Hex("hello").toUpperCase() });
  expect(ObservationSchema.safeParse(upper).success).toBe(false);
  const short = snapshot("hello", { text_hash: sha256Hex("hello").slice(0, 63) });
  expect(ObservationSchema.safeParse(short).success).toBe(false);
});

test("CONTRACT: host with a path, port or scheme is rejected", () => {
  for (const host of ["example.com/a", "example.com:8080", "https://example.com", "example.com?q=1", "exa mple.com", ""]) {
    expect(bothAccept("observation", ObservationSchema, { ...focus, host })).toEqual({ zod: false, json: false });
  }
  for (const host of ["example.com", "docs.example.co.uk", "localhost"]) {
    expect(bothAccept("observation", ObservationSchema, { ...focus, host })).toEqual({ zod: true, json: true });
  }
});

test("CONTRACT: objects array of 501 is rejected", () => {
  const validate = ajv().compile(readSchema("ingest-envelope"));
  const mk = (n: number) => envelope("observation_batch", Array.from({ length: n }, () => focus));
  expect(IngestEnvelopeSchema.safeParse(mk(500)).success).toBe(true);
  expect(validate(mk(500))).toBe(true);
  expect(IngestEnvelopeSchema.safeParse(mk(501)).success).toBe(false);
  expect(validate(mk(501))).toBe(false);
  expect(IngestEnvelopeSchema.safeParse(mk(0)).success).toBe(false);
  expect(validate(mk(0))).toBe(false);
  expect(IngestEnvelopeSchema.safeParse(mk(1)).success).toBe(true);
});

test("CONTRACT: ReviewEvent, NoticeAck, KeyframeMeta and StepResult validate their fixtures", () => {
  const cases: [string, { safeParse(v: unknown): { success: boolean } }, Record<string, unknown>, Record<string, unknown>][] = [
    ["review-event", ReviewEventSchema, reviewEvent, { ...reviewEvent, decision: "maybe" }],
    ["notice-ack", NoticeAckSchema, noticeAck, { ...noticeAck, notice_version: "v".repeat(33) }],
    ["keyframe-meta", KeyframeMetaSchema, keyframeMeta, { ...keyframeMeta, width: 1281 }],
    ["step-result", StepResultSchema, stepResult, { ...stepResult, outcome: "done" }],
  ];
  for (const [name, schema, good, bad] of cases) {
    expect(bothAccept(name, schema, good)).toEqual({ zod: true, json: true });
    expect(bothAccept(name, schema, bad)).toEqual({ zod: false, json: false });
    expect(bothAccept(name, schema, { ...good, extra: 1 })).toEqual({ zod: false, json: false });
  }
  expect(ReviewEventSchema.safeParse({ ...reviewEvent, review_seconds: -1 }).success).toBe(false);
  expect(ReviewEventSchema.safeParse({ ...reviewEvent, surface: "web" }).success).toBe(false);
  expect(KeyframeMetaSchema.safeParse({ ...keyframeMeta, bytes: 524289 }).success).toBe(false);
  expect(KeyframeMetaSchema.safeParse({ ...keyframeMeta, bytes: 0 }).success).toBe(false);
  expect(KeyframeMetaSchema.safeParse({ ...keyframeMeta, phash: "0123456789abcde" }).success).toBe(false);
  expect(StepResultSchema.safeParse({ ...stepResult, detail_code: "d".repeat(65) }).success).toBe(false);
  const { detail_code: _d, ...noDetail } = stepResult;
  expect(StepResultSchema.safeParse(noDetail).success).toBe(true);
  // the id is a ULID
  expect(NoticeAckSchema.safeParse({ ...noticeAck, id: "not-a-ulid" }).success).toBe(false);
});

test("CONTRACT: generated JSON Schemas are fresh", () => {
  const generated = generateSchemas();
  expect(Object.keys(generated).length).toBeGreaterThanOrEqual(9);
  for (const [file, text] of Object.entries(generated)) {
    expect(readFileSync(join(SCHEMA_DIR, file), "utf8")).toBe(text);
  }
  // regenerating twice gives identical bytes
  expect(generateSchemas()).toEqual(generated);
});

test("CONTRACT: every schema declares Draft 2020-12", () => {
  const generated = generateSchemas();
  for (const [file, text] of Object.entries(generated)) {
    const s = JSON.parse(text) as Record<string, unknown>;
    expect(s["$schema"]).toBe("https://json-schema.org/draft/2020-12/schema");
    expect(s["$id"]).toBe(`https://offload.consultance.ai/schemas/${file.replace(/\.schema\.json$/, "")}.json`);
  }
});

test("CONTRACT: Figure requires arithmetic, evidence and a nullable source_purged_at", () => {
  const base = { value: 3.1, unit: "hours_per_week", arithmetic: "6 times × 31 min median = 3.1 h", evidence: [{ kind: "episode", id: "ep_01J" }], source_purged_at: null };
  const fig = makeFigure(base);
  expect(bothAccept("figure", FigureSchema, fig)).toEqual({ zod: true, json: true });
  const purged = makeFigure({ ...base, source_purged_at: "2026-11-14T00:00:00Z" });
  expect(bothAccept("figure", FigureSchema, purged)).toEqual({ zod: true, json: true });
  for (const drop of ["arithmetic", "evidence", "source_purged_at", "unit", "value"] as const) {
    const { [drop]: _x, ...rest } = fig;
    expect(bothAccept("figure", FigureSchema, rest)).toEqual({ zod: false, json: false });
  }
  expect(FigureSchema.safeParse({ ...fig, arithmetic: "" }).success).toBe(false);
  expect(FigureSchema.safeParse({ ...fig, source_purged_at: undefined }).success).toBe(false);
  expect(FigureSchema.safeParse({ ...fig, extra: 1 }).success).toBe(false);
});

test("CONTRACT: Figure id is fig_ plus 16 hex of the JCS hash", () => {
  const body = { value: 3.1, unit: "hours_per_week", arithmetic: "6 times × 31 min median = 3.1 h", evidence: [{ kind: "episode", id: "ep_01J" }], source_purged_at: null };
  const id = figureId(body);
  expect(id).toMatch(/^fig_[0-9a-f]{16}$/);
  expect(id).toBe(`fig_${sha256Hex(jcs(body)).slice(0, 16)}`);
  // key order does not change it; a changed value does
  expect(figureId({ source_purged_at: null, evidence: body.evidence, arithmetic: body.arithmetic, unit: body.unit, value: 3.1 })).toBe(id);
  expect(figureId({ ...body, value: 3.2 })).not.toBe(id);
  // an id that is not the hash of the rest is rejected
  expect(FigureSchema.safeParse({ ...body, id }).success).toBe(true);
  expect(FigureSchema.safeParse({ ...body, id: "fig_0000000000000000" }).success).toBe(false);
  expect(FigureSchema.safeParse({ ...body, id: "fig_XYZ" }).success).toBe(false);
});

test("CONTRACT: error envelope codes are the closed list in API.md", () => {
  const api = readFileSync(join(import.meta.dir, "../../../../docs/API.md"), "utf8");
  const section = api.slice(api.indexOf("### Error envelope"), api.indexOf("### Figure"));
  const rows = section.split("\n").filter((l) => /^\| (\d{3}|5xx) \|/.test(l));
  expect(rows.length).toBe(9);
  const codesIn = (l: string) => [...l.matchAll(/`([a-z_]+)`/g)].map((m) => m[1]!).filter((c) => c !== "rule_id");
  const docCodes = rows.flatMap(codesIn);
  const known: string[] = [...ERROR_CODES];
  expect(known.sort()).toEqual([...docCodes].sort());
  // each status row in the doc matches ERROR_CODES_BY_STATUS
  for (const l of rows) {
    const status = l.startsWith("| 5xx") ? 500 : Number(/^\| (\d{3})/.exec(l)![1]);
    const codes = codesIn(l);
    const listed: string[] = [...ERROR_CODES_BY_STATUS[status as keyof typeof ERROR_CODES_BY_STATUS]];
    expect(listed).toEqual(codes);
  }
  for (const c of ["clock_skew", "nonce_used", "recipient_not_allowed"]) expect(known).toContain(c);
  const requestId = "req_01JCZ3X5Q8M2N4P6R8T0V1W2Y3";
  const base = { error: { code: "clock_skew", message: "sent_at is more than 10 minutes off", request_id: requestId } };
  expect(bothAccept("error-envelope", ErrorEnvelopeSchema, base)).toEqual({ zod: true, json: true });
  const withRule = { error: { ...base.error, code: "policy_denied", rule_id: "core.commit.quiet_hours" } };
  expect(bothAccept("error-envelope", ErrorEnvelopeSchema, withRule)).toEqual({ zod: true, json: true });
  for (const bad of [
    { error: { ...base.error, code: "teapot" } },
    { error: { ...base.error, request_id: "01JCZ3X5Q8M2N4P6R8T0V1W2Y3" } },
    { error: { ...base.error, request_id: "req_short" } },
    { error: { code: "server_error", message: "x" } },
    { error: { ...base.error, extra: 1 } },
    { ...base, extra: 1 },
  ]) {
    expect(bothAccept("error-envelope", ErrorEnvelopeSchema, bad)).toEqual({ zod: false, json: false });
  }
});

test("CONTRACT: receipt rejection codes are the closed list including not_enabled", () => {
  const rejections: string[] = [...RECEIPT_REJECTION_CODES];
  expect(rejections.sort()).toEqual(
    ["consent_missing", "excluded", "leak_detected", "not_enabled", "rate_limited", "schema_invalid", "server_error", "too_old", "unknown_kind"],
  );
  const ok = { accepted: [ULID_A], rejected: [{ id: "01JCZ3X5Q8M2N4P6R8T0V1W2Y4", code: "not_enabled" }] };
  expect(bothAccept("ingest-receipt", IngestReceiptSchema, ok)).toEqual({ zod: true, json: true });
  expect(bothAccept("ingest-receipt", IngestReceiptSchema, { accepted: [], rejected: [] })).toEqual({ zod: true, json: true });
  // an object whose own id was malformed can still be named in the receipt
  expect(IngestReceiptSchema.safeParse({ accepted: [], rejected: [{ id: "bad id", code: "schema_invalid" }] }).success).toBe(true);
  expect(bothAccept("ingest-receipt", IngestReceiptSchema, { accepted: [], rejected: [{ id: ULID_A, code: "policy_denied" }] })).toEqual({ zod: false, json: false });
  expect(bothAccept("ingest-receipt", IngestReceiptSchema, { accepted: [] })).toEqual({ zod: false, json: false });
  void TS;
});
