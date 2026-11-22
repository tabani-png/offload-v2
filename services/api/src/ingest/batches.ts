import type { Context, Hono } from "hono";
import {
  ObservationSchema, UPLOAD_KINDS, sha256Hex, type IngestReceipt, type Observation, type ReceiptRejectionCode,
} from "@offload/contracts";
import { appendAudit, uuidv7, withTenant, type Tx } from "@offload/db";
import { BUILTIN_EXCLUSIONS, matchExclusion, scanForLeak, type DetectorName, type ExclusionRule } from "@offload/masking";
import { isCanonicalBody, parseOffloadSignature, verifyDeviceSignature } from "../auth/signature.ts";
import { ApiError, invalidRequest, unauthenticated } from "../http.ts";
import { authenticateDevice, createRateLimiter, type DevicePrincipal, type IngestDeps } from "./context.ts";
import { hasUploadConsent } from "./consent.ts";

/**
 * POST /v1/ingest/batches, GET /v1/ingest/config and POST /v1/ingest/keyframes (ADR 0020, docs/API.md section 3,
 * ARCHITECTURE.md section 3). The order of checks below is the contract: each failure stops the request, and a
 * whole-request failure stores nothing.
 */

export const INGEST_MAX_BYTES = 1024 * 1024;
export const INGEST_MAX_OBJECTS = 500;
export const INGEST_FLUSH_SECONDS = 300;
export const INGEST_RATE_LIMIT = 60;
const SKEW_MS = 10 * 60_000;
const TOO_OLD_MS = 7 * 86_400_000;
const FUTURE_MS = 10 * 60_000;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const RFC3339_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;
const ENVELOPE_KEYS = ["device_id", "kind", "objects", "sent_at", "seq", "v"];
const DISABLED_KINDS = new Set(["review_event", "notice_ack", "step_result"]);

const schemaInvalid = (message: string) => new ApiError(400, "schema_invalid", message);

/** Reads the request body, refusing more than `max` bytes without buffering past the limit. */
async function readBounded(c: Context, max: number): Promise<Uint8Array> {
  const declared = c.req.header("content-length");
  if (declared !== undefined && Number(declared) > max) throw new ApiError(413, "too_large", "body too large");
  const stream = c.req.raw.body;
  if (!stream) return new Uint8Array(0);
  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > max) {
      await reader.cancel().catch(() => {});
      throw new ApiError(413, "too_large", "body too large");
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let at = 0;
  for (const ch of chunks) {
    out.set(ch, at);
    at += ch.byteLength;
  }
  return out;
}

interface Verdict {
  id: string;
  code?: ReceiptRejectionCode;
  /** The detector that fired, for leak_detected (audit details). */
  detector?: DetectorName;
  obs?: Observation;
  day?: string;
}

const receiptIdOf = (o: unknown, i: number): string =>
  typeof o === "object" && o !== null && typeof (o as { id?: unknown }).id === "string" && (o as { id: string }).id.length >= 1 && (o as { id: string }).id.length <= 64
    ? (o as { id: string }).id
    : `object-${i}`;

/** The text fields a leak can sit in, for each observation kind. */
function scannedFields(o: Observation): string[] {
  const out: string[] = [o.kind === "text_snapshot" ? o.text : ""];
  if ("app_bundle_id" in o && o.app_bundle_id !== undefined) out.push(o.app_bundle_id);
  if ("app_name" in o && o.app_name !== undefined) out.push(o.app_name);
  if ("title" in o && o.title !== undefined) out.push(o.title);
  return out.filter((s) => s !== "");
}

interface Context7 {
  now: number;
  consented: boolean;
  rules: ExclusionRule[];
  openImports: Set<string>;
}

function judge(raw: unknown, i: number, k: Context7): Verdict {
  const id = receiptIdOf(raw, i);
  const parsed = ObservationSchema.safeParse(raw);
  if (!parsed.success) return { id, code: "schema_invalid" };
  const o = parsed.data;
  // uuids are compared and stored in lower case (the database returns them so; forget lowercases too).
  if (o.import_id !== undefined) o.import_id = o.import_id.toLowerCase();
  const ts = Date.parse(o.ts);
  if (Number.isNaN(ts)) return { id, code: "schema_invalid" };
  const isImport = o.source === "import";
  // An import_id belongs only on an imported object, and only of an import space the member opened (m3-05b).
  if (!isImport && o.import_id !== undefined) return { id, code: "schema_invalid" };
  if (isImport && !k.openImports.has(o.import_id!)) return { id, code: "schema_invalid" };
  if (!isImport && ts < k.now - TOO_OLD_MS) return { id, code: "too_old" };
  if (ts > k.now + FUTURE_MS) return { id, code: "schema_invalid" };
  if (!k.consented) return { id, code: "consent_missing" };
  for (const field of scannedFields(o)) {
    const detector = scanForLeak(field);
    if (detector) return { id, code: "leak_detected", detector };
  }
  const subject = {
    app_bundle_id: "app_bundle_id" in o ? o.app_bundle_id : undefined,
    host: "host" in o ? o.host : undefined,
    title: "title" in o ? o.title : undefined,
  };
  if (matchExclusion(k.rules, subject)) return { id, code: "excluded" };
  // Imported objects carry the day they were ingested, not the day they describe (ADR 0020).
  const day = new Date(isImport ? k.now : ts).toISOString().slice(0, 10);
  return { id, obs: o, day };
}

async function insertObservation(tx: Tx, p: DevicePrincipal, v: Verdict): Promise<void> {
  const o = v.obs!;
  const common = [p.tenantId, p.deviceId, o.id, v.day, p.memberId, o.ts, o.source ?? "live", o.import_id ?? null];
  if (o.kind === "text_snapshot") {
    await tx.query(
      `insert into observation_texts (tenant_id, device_id, object_id, day, member_id, ts, source, import_id, text, text_hash, text_source, app_bundle_id)
       values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
       on conflict (tenant_id, device_id, object_id, day) do nothing`,
      [...common, o.text, o.text_hash, o.text_source, o.app_bundle_id],
    );
    return;
  }
  await tx.query(
    `insert into observations (tenant_id, device_id, object_id, day, member_id, ts, source, import_id, kind, app_bundle_id, app_name, title, host, doc, keys, clicks, reason, perm)
     values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18)
     on conflict (tenant_id, device_id, object_id, day) do nothing`,
    [
      ...common, o.kind,
      "app_bundle_id" in o ? o.app_bundle_id : null, "app_name" in o ? o.app_name : null, "title" in o ? (o.title ?? null) : null,
      "host" in o ? (o.host ?? null) : null, "doc" in o ? (o.doc ?? null) : null,
      "keys" in o ? o.keys : null, "clicks" in o ? o.clicks : null, "reason" in o ? o.reason : null,
      "perm" in o ? JSON.stringify(o.perm) : null,
    ],
  );
}

/** The receipt for these verdicts, in object order. */
const receiptOf = (verdicts: Verdict[]): IngestReceipt => ({
  accepted: verdicts.filter((v) => v.code === undefined).map((v) => v.id),
  rejected: verdicts.filter((v) => v.code !== undefined).map((v) => ({ id: v.id, code: v.code! })),
});

/** Import ids named by accepted imported objects. */
const importIdsOf = (verdicts: Verdict[]): string[] =>
  [...new Set(verdicts.flatMap((v) => (v.obs?.source === "import" ? [v.obs.import_id!] : [])))];

/**
 * Re-reads the batch's import spaces in the insert transaction under FOR NO KEY UPDATE: forget takes the row FOR
 * UPDATE, so an import space forgotten after the per-object check rejects its objects here instead of leaving orphan
 * rows. Not FOR SHARE: two devices of one member writing into one import space would each hold a share lock and then
 * deadlock on the first_day/last_day update; this lock lets the second wait for the first instead.
 */
async function recheckImports(tx: Tx, p: DevicePrincipal, verdicts: Verdict[]): Promise<Verdict[]> {
  const ids = importIdsOf(verdicts);
  if (ids.length === 0) return verdicts;
  const open = new Set((await tx.query<{ id: string }>(
    "select id from imports where member_id = $1 and wiped_at is null and id = any($2::uuid[]) order by id for no key update", [p.memberId, ids],
  )).rows.map((r) => r.id));
  return verdicts.map((v) => (v.obs?.source === "import" && !open.has(v.obs.import_id!) ? { id: v.id, code: "schema_invalid" as const } : v));
}

/** Widens each import space's first_day and last_day to the UTC dates of its accepted objects' ts. */
async function widenImportDays(tx: Tx, p: DevicePrincipal, verdicts: Verdict[]): Promise<void> {
  for (const importId of importIdsOf(verdicts)) {
    const days = verdicts.filter((v) => v.obs?.import_id === importId).map((v) => new Date(v.obs!.ts).toISOString().slice(0, 10)).sort();
    await tx.query(
      "update imports set first_day = least(first_day, $3::date), last_day = greatest(last_day, $4::date) where member_id = $1 and id = $2",
      [p.memberId, importId, days[0], days[days.length - 1]],
    );
  }
}

/**
 * observations.ingested: one event for the batch's live objects and one per import space, so forget scope import
 * can delete exactly the events that name it. Ids and counts only.
 */
async function writeIngestedEvents(tx: Tx, p: DevicePrincipal, seq: number, verdicts: Verdict[]): Promise<void> {
  const groups = new Map<string | null, number>();
  for (const v of verdicts) {
    if (!v.obs) continue;
    const key = v.obs.source === "import" ? v.obs.import_id! : null;
    groups.set(key, (groups.get(key) ?? 0) + 1);
  }
  for (const [importId, accepted] of groups) {
    const payload = { device_id: p.deviceId, member_id: p.memberId, seq, accepted, ...(importId === null ? {} : { import_id: importId }) };
    await tx.query(
      "insert into events_outbox (tenant_id, id, type, version, payload) values ($1, $2, 'observations.ingested', 1, $3)",
      [p.tenantId, uuidv7(), JSON.stringify(payload)],
    );
  }
}

interface StoredBatch {
  body_sha256: string;
  receipt: IngestReceipt | null;
}

export function registerIngestRoutes(app: Hono, deps: IngestDeps): void {
  const limiter = createRateLimiter({ limit: INGEST_RATE_LIMIT, windowMs: 60_000, clock: deps.clock });

  app.get("/v1/ingest/config", async (c) => {
    const p = await authenticateDevice(c, deps);
    const own = await withTenant(deps.pool, p.ctx, async (tx) =>
      (await tx.query<{ kind: ExclusionRule["kind"]; value: string }>("select kind, value from exclusions where member_id = $1 and source = 'user' order by id", [p.memberId])).rows);
    c.header("cache-control", "no-store");
    return c.json({
      flush_seconds: INGEST_FLUSH_SECONDS, max_objects: INGEST_MAX_OBJECTS, max_bytes: INGEST_MAX_BYTES,
      exclusions: [...BUILTIN_EXCLUSIONS.map((e) => ({ kind: e.kind, value: e.value, source: "builtin" })), ...own.map((e) => ({ kind: e.kind, value: e.value, source: "user" }))],
      keyframes_to_cloud: false,
    });
  });

  // Keyframe opt-in arrives in M5: until then no device may upload one.
  app.post("/v1/ingest/keyframes", async (c) => {
    await authenticateDevice(c, deps);
    throw new ApiError(403, "consent_missing", "keyframes are not uploaded to the cloud");
  });

  app.post("/v1/ingest/batches", async (c) => {
    // 1. device token, then the rate limit.
    const p = await authenticateDevice(c, deps);
    limiter.hit(p.deviceId);

    // 2. size, JCS form, signature over the exact bytes.
    const bytes = await readBounded(c, INGEST_MAX_BYTES);
    let text: string;
    try {
      text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes);
    } catch {
      throw invalidRequest("body is not UTF-8");
    }
    if (!isCanonicalBody(text)) throw invalidRequest("body must be JSON in canonical (JCS) form");
    const sig = parseOffloadSignature(c.req.header("offload-signature"));
    if (!sig) throw unauthenticated("Offload-Signature is required");
    const publicJwk = await withTenant(deps.pool, p.ctx, async (tx) =>
      (await tx.query<{ public_jwk: unknown }>("select public_jwk from devices where id = $1", [p.deviceId])).rows[0]?.public_jwk);
    if (!(await verifyDeviceSignature(publicJwk, bytes, sig.sig))) throw unauthenticated("bad signature");
    const env = JSON.parse(text) as unknown;
    if (typeof env !== "object" || env === null || Array.isArray(env)) throw invalidRequest("body must be an envelope object");
    const e = env as Record<string, unknown>;

    // 3. the envelope and the key id name the token's own device.
    if (e["device_id"] !== p.deviceId || sig.keyid !== p.deviceId) throw new ApiError(403, "forbidden", "device_id does not match the device token");

    // 4. seq: a resend of the same bytes gets the stored receipt, anything not above last_seq is a replay.
    const seq = e["seq"];
    if (typeof seq !== "number" || !Number.isSafeInteger(seq) || seq < 0) throw schemaInvalid("seq must be a non-negative integer");
    const bodySha256 = sha256Hex(text);
    const state = await withTenant(deps.pool, p.ctx, async (tx) => {
      const stored = (await tx.query<StoredBatch>("select body_sha256, receipt from ingest_batches where device_id = $1 and seq = $2", [p.deviceId, seq])).rows[0];
      const last = (await tx.query<{ last_seq: string }>("select last_seq from devices where id = $1", [p.deviceId])).rows[0];
      return { stored, lastSeq: Number(last?.last_seq ?? 0) };
    });
    const replay = (s: StoredBatch) => {
      if (s.body_sha256 !== bodySha256) throw new ApiError(409, "seq_replay", "seq was already used for different bytes");
      if (!s.receipt) throw new ApiError(500, "server_error", "something went wrong");
      return c.json(s.receipt);
    };
    if (state.stored) return replay(state.stored);
    if (seq <= state.lastSeq) throw new ApiError(409, "seq_replay", "seq is not above the last accepted seq");

    // 5. sent_at within the clock window.
    const sentAt = e["sent_at"];
    if (typeof sentAt !== "string" || !RFC3339_RE.test(sentAt) || Number.isNaN(Date.parse(sentAt))) throw schemaInvalid("sent_at must be RFC 3339 with an offset");
    const now = deps.clock.now().getTime();
    if (Math.abs(now - Date.parse(sentAt)) > SKEW_MS) throw new ApiError(400, "clock_skew", "sent_at is more than 10 minutes from server time");

    // 6. envelope shape and kind.
    const kind = e["kind"];
    if (typeof kind !== "string" || !(UPLOAD_KINDS as readonly string[]).includes(kind) || kind === "keyframe") {
      throw new ApiError(400, "unknown_kind", "unknown upload kind for this route");
    }
    if (Object.keys(e).sort().join(",") !== ENVELOPE_KEYS.join(",") || e["v"] !== 1 || !UUID_RE.test(String(e["device_id"]))) throw schemaInvalid("invalid envelope");
    const objects = e["objects"];
    if (!Array.isArray(objects) || objects.length < 1 || objects.length > INGEST_MAX_OBJECTS) throw schemaInvalid("objects holds 1 to 500 items");

    // 7. per object.
    let verdicts: Verdict[];
    if (DISABLED_KINDS.has(kind)) {
      verdicts = objects.map((o, i) => ({ id: receiptIdOf(o, i), code: "not_enabled" as const }));
    } else {
      const k = await withTenant(deps.pool, p.ctx, async (tx): Promise<Context7> => {
        const own = (await tx.query<ExclusionRule>("select kind, value from exclusions where member_id = $1", [p.memberId])).rows;
        const importIds = [...new Set(objects.flatMap((o) => (typeof o === "object" && o !== null && typeof (o as { import_id?: unknown }).import_id === "string" ? [(o as { import_id: string }).import_id.toLowerCase()] : [])))]
          .filter((x) => UUID_RE.test(x));
        const open = importIds.length === 0 ? [] : (await tx.query<{ id: string }>("select id from imports where member_id = $1 and wiped_at is null and id = any($2::uuid[])", [p.memberId, importIds])).rows;
        return { now, consented: await hasUploadConsent(tx, p.memberId), rules: [...BUILTIN_EXCLUSIONS, ...own], openImports: new Set(open.map((r) => r.id)) };
      });
      verdicts = objects.map((o, i) => judge(o, i, k));
    }
    // 8. one transaction: objects, batch row with receipt, last_seq, outbox event, leak audits.
    const stored = await withTenant(deps.pool, p.ctx, async (tx) => {
      // The device row is the lock that serialises two batches of one device (and a resend racing its original).
      const dev = (await tx.query<{ last_seq: string }>("select last_seq from devices where tenant_id = $1 and id = $2 for update", [p.tenantId, p.deviceId])).rows[0];
      const again = (await tx.query<StoredBatch>("select body_sha256, receipt from ingest_batches where device_id = $1 and seq = $2", [p.deviceId, seq])).rows[0];
      if (again) return { replayOf: again, receipt: null };
      if (!dev || seq <= Number(dev.last_seq)) throw new ApiError(409, "seq_replay", "seq is not above the last accepted seq");
      const final = await recheckImports(tx, p, verdicts);
      const receipt = receiptOf(final);
      for (const v of final) if (v.obs) await insertObservation(tx, p, v);
      await widenImportDays(tx, p, final);
      await tx.query(
        "insert into ingest_batches (tenant_id, device_id, seq, kind, body_sha256, object_count, receipt) values ($1, $2, $3, $4, $5, $6, $7)",
        [p.tenantId, p.deviceId, seq, kind, bodySha256, objects.length, JSON.stringify(receipt)],
      );
      await tx.query("update devices set last_seq = $3 where tenant_id = $1 and id = $2", [p.tenantId, p.deviceId, seq]);
      if (kind === "observation_batch") await writeIngestedEvents(tx, p, seq, final);
      for (const v of final) {
        if (v.code === "leak_detected") {
          await appendAudit(tx, {
            principalId: p.deviceId, action: "privacy.leak_blocked", subjectType: "observation", subjectId: v.id,
            details: { object_id: v.id, detector: v.detector! },
          });
        }
      }
      return { replayOf: null, receipt };
    });
    if (stored.replayOf) return replay(stored.replayOf);

    // 9. the receipt.
    c.header("cache-control", "no-store");
    return c.json(stored.receipt!);
  });
}
