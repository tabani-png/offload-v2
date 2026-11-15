import { BrokerError } from "../errors.ts";

/**
 * The broker's only outbound HTTP (SECURITY_PRIVACY section 9: `fetch` may appear only here in this process). Redirects
 * are never followed, so a credential cannot be replayed to another host. Never called inside a transaction.
 */

export interface UpstreamResponse {
  status: number;
  contentType: string | null;
  body: string;
}

const MAX_BODY_BYTES = 8_000_000;
const TIMEOUT_MS = 30_000;

export async function send(input: { method: string; url: string; headers: Record<string, string>; body?: string | null }): Promise<UpstreamResponse> {
  try {
    const init: RequestInit = { method: input.method, headers: input.headers, redirect: "manual", signal: AbortSignal.timeout(TIMEOUT_MS) };
    if (input.body !== undefined && input.body !== null) init.body = input.body;
    const res = await globalThis.fetch(input.url, init);
    const buf = new Uint8Array(await res.arrayBuffer());
    if (buf.length > MAX_BODY_BYTES) throw new BrokerError("upstream_unreachable", "the upstream response is too large");
    return { status: res.status, contentType: res.headers.get("content-type"), body: new TextDecoder().decode(buf) };
  } catch (e) {
    if (e instanceof BrokerError) throw e;
    throw new BrokerError("upstream_unreachable", "the upstream request failed");
  }
}

/** POST application/x-www-form-urlencoded and parse a JSON answer (OAuth token endpoint). */
export async function postForm(url: string, form: Record<string, string>): Promise<{ status: number; json: Record<string, unknown> | null }> {
  const r = await send({
    method: "POST", url, headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
    body: new URLSearchParams(form).toString(),
  });
  let json: Record<string, unknown> | null = null;
  try {
    const v: unknown = JSON.parse(r.body);
    if (v !== null && typeof v === "object" && !Array.isArray(v)) json = v as Record<string, unknown>;
  } catch {
    /* not JSON */
  }
  return { status: r.status, json };
}

/** GET with a bearer token, parse JSON (OAuth userinfo). */
export async function getJson(url: string, bearer: string): Promise<{ status: number; json: Record<string, unknown> | null }> {
  const r = await send({ method: "GET", url, headers: { authorization: `Bearer ${bearer}`, accept: "application/json" } });
  let json: Record<string, unknown> | null = null;
  try {
    const v: unknown = JSON.parse(r.body);
    if (v !== null && typeof v === "object" && !Array.isArray(v)) json = v as Record<string, unknown>;
  } catch {
    /* not JSON */
  }
  return { status: r.status, json };
}
