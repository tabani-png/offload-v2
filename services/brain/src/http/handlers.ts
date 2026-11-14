// Framework-agnostic handlers (web-standard Request -> Response) for the user model routes in docs/API.md:
// GET/PATCH /v1/profile, GET /v1/records/{days,weeks,months,quarters}/{key}, GET /v1/review/week?w=,
// POST /v1/review/answers. services/api mounts them after auth (session or member token) and CSRF.
// Returns null for any other path or method, so the caller can fall through. Handlers only read, except PATCH
// /v1/profile and POST /v1/review/answers; records are written by the member update job.
import { applyProfilePatch } from "../profile/profile.ts";
import { dayOf, isDay, isIsoWeek, isoWeekOf, MONTH_RE, QUARTER_RE } from "../records/dates.ts";
import { parseReviewAnswer } from "../review/answers.ts";
import { buildWeekReview } from "../review/week-review.ts";
import { requestId as newRequestId } from "../store/ids.ts";
import * as repo from "../store/repository.ts";
import type { RunInTenant, Tx } from "../store/tenant.ts";

export interface UserModelAuth {
  tenantId: string;
  memberId: string;
  principalId: string;
  tenantRole: string;
}

export interface HandlerDeps {
  runInTenant: RunInTenant;
  now: () => number;
  /** `req_` + ULID; generated when absent. */
  requestId?: () => string;
}

export const MAX_BODY_BYTES = 64 * 1024;
const JSON_TYPE = "application/json; charset=utf-8";

type ErrorCode = "invalid_request" | "schema_invalid" | "not_found" | "too_large" | "leak_detected" | "server_error";
const STATUS: Record<ErrorCode, number> = { invalid_request: 400, schema_invalid: 400, not_found: 404, too_large: 413, leak_detected: 422, server_error: 500 };

class HttpError extends Error {
  constructor(readonly code: ErrorCode, message: string) {
    super(message);
  }
}

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "content-type": JSON_TYPE, "cache-control": "no-store" } });

/** Reads a JSON body of at most MAX_BODY_BYTES. Writes must say `application/json` (the old jsonBody rule, kept as
 * defence in depth behind CSRF in services/api). The body is read as a stream and abandoned past the cap. */
async function readJson(req: Request): Promise<unknown> {
  if (!/^application\/json\s*(?:;.*)?$/i.test(req.headers.get("content-type") ?? "")) throw new HttpError("invalid_request", "send the body as application/json");
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY_BYTES) throw new HttpError("too_large", "the body is too large");
  const chunks: Uint8Array[] = [];
  let size = 0;
  if (req.body !== null) {
    const reader = req.body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_BODY_BYTES) {
        await reader.cancel();
        throw new HttpError("too_large", "the body is too large");
      }
      chunks.push(value);
    }
  }
  const bytes = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) {
    bytes.set(c, at);
    at += c.byteLength;
  }
  try {
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    // Not JSON at all: a request error, not a schema error.
    throw new HttpError("invalid_request", "the body is not JSON");
  }
}

/** A malformed escape decodes to a key no validator accepts, so it ends as 400 invalid_request inside the handler. */
function safeDecode(s: string): string {
  try {
    return decodeURIComponent(s);
  } catch {
    return "\u0000";
  }
}

type Route =
  | { kind: "profile_get" }
  | { kind: "profile_patch" }
  | { kind: "record"; record: "days" | "weeks" | "months" | "quarters"; key: string }
  | { kind: "review_week"; week: string | null }
  | { kind: "review_answer" };

function route(req: Request): Route | null {
  const url = new URL(req.url);
  const path = url.pathname;
  if (path === "/v1/profile") return req.method === "GET" ? { kind: "profile_get" } : req.method === "PATCH" ? { kind: "profile_patch" } : null;
  const m = /^\/v1\/records\/(days|weeks|months|quarters)\/([^/]+)$/.exec(path);
  if (m !== null) return req.method === "GET" ? { kind: "record", record: m[1] as "days" | "weeks" | "months" | "quarters", key: safeDecode(m[2]!) } : null;
  if (path === "/v1/review/week") return req.method === "GET" ? { kind: "review_week", week: url.searchParams.get("w") } : null;
  if (path === "/v1/review/answers") return req.method === "POST" ? { kind: "review_answer" } : null;
  return null;
}

/** The member's current ISO week, in their timezone. */
async function currentWeek(tx: Tx, now: number): Promise<string> {
  const p = await repo.getProfile(tx);
  return isoWeekOf(dayOf(now, p.timezone));
}

async function handle(r: Route, body: unknown, tx: Tx, now: number): Promise<Response> {
  switch (r.kind) {
    case "profile_get":
      return json(200, await repo.getProfile(tx));
    case "profile_patch": {
      await repo.lockProfile(tx);
      const result = applyProfilePatch(await repo.getProfile(tx), body, now);
      if (!result.ok) throw new HttpError("schema_invalid", result.message);
      return json(200, await repo.saveProfile(tx, result));
    }
    case "record": {
      const { record, key } = r;
      if (record === "days") {
        if (!isDay(key)) throw new HttpError("invalid_request", "the day must be YYYY-MM-DD");
        const d = await repo.getDayRecord(tx, key);
        if (d === null) throw new HttpError("not_found", "no day record for that day");
        return json(200, d);
      }
      if (record === "weeks") {
        if (!isIsoWeek(key)) throw new HttpError("invalid_request", "the week must be YYYY-Www");
        if (key > (await currentWeek(tx, now))) throw new HttpError("not_found", "that week has not happened yet");
        const w = await repo.getWeekRecord(tx, key);
        if (w === null) throw new HttpError("not_found", "no week record for that week");
        return json(200, w);
      }
      const kind = record === "months" ? "month" : "quarter";
      if (!(kind === "month" ? MONTH_RE : QUARTER_RE).test(key)) throw new HttpError("invalid_request", kind === "month" ? "the month must be YYYY-MM" : "the quarter must be YYYY-Qn");
      const rec = await repo.getRollup(tx, kind, key);
      if (rec === null) throw new HttpError("not_found", `no ${kind} record for that ${kind}`);
      return json(200, rec);
    }
    case "review_week": {
      const w = r.week ?? "";
      if (!isIsoWeek(w)) throw new HttpError("invalid_request", "w must be YYYY-Www");
      if (w > (await currentWeek(tx, now))) throw new HttpError("not_found", "that week has not happened yet");
      const week = await repo.getWeekRecord(tx, w);
      if (week === null) throw new HttpError("not_found", "no week record for that week");
      const answers = (await repo.listReviewAnswers(tx)).filter((a) => a.iso_week === w);
      return json(200, buildWeekReview({ week, goals: (await repo.getProfile(tx)).goals, opportunities: await repo.listOpportunities(tx, w), answers }));
    }
    case "review_answer": {
      const profile = await repo.getProfile(tx);
      const parsed = parseReviewAnswer(body, { activeGoalIds: profile.goals.map((g) => g.id), currentWeek: isoWeekOf(dayOf(now, profile.timezone)), now });
      if (!parsed.ok) throw new HttpError(parsed.code, parsed.message);
      const saved = await repo.saveReviewAnswer(tx, parsed.answer);
      await repo.applyAnswerToOpportunity(tx, saved);
      return json(200, saved);
    }
  }
}

export async function handleUserModelRequest(req: Request, auth: UserModelAuth, deps: HandlerDeps): Promise<Response | null> {
  const r = route(req);
  if (r === null) return null;
  const rid = (deps.requestId ?? newRequestId)();
  const fail = (code: ErrorCode, message: string) => json(STATUS[code], { error: { code, message, request_id: rid } });
  try {
    // The body is read (or refused) before the transaction opens: a slow client must not hold a pooled connection
    // with an open transaction (ADR 0013: no I/O inside withTenant).
    const body = r.kind === "profile_patch" || r.kind === "review_answer" ? await readJson(req) : undefined;
    return await deps.runInTenant({ tenantId: auth.tenantId, memberId: auth.memberId, principalId: auth.principalId, tenantRole: auth.tenantRole }, (tx) => handle(r, body, tx, deps.now()));
  } catch (err) {
    if (err instanceof HttpError) return fail(err.code, err.message);
    if (err instanceof repo.LeakError) return fail("leak_detected", "that text holds an email address or a link and cannot be stored");
    // No detail leaves the server; the caller logs the request id.
    return fail("server_error", "something went wrong");
  }
}
