import type { Hono } from "hono";
import { withTenant } from "@offload/db";
import { ApiError, invalidRequest } from "../http.ts";
import { authenticateDevice, type IngestDeps } from "./context.ts";

/**
 * Pseudonym key wraps (ADR 0028, docs/API.md "Devices"). The server stores ciphertext only, per device, and gives a
 * device back only its own row; the key itself never reaches the server.
 */

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
/** Opaque ciphertext text: base64 or base64url with the usual separators; never interpreted here. */
const WRAP_RE = /^[A-Za-z0-9_.+/=-]{1,8192}$/;
const NOT_FOUND = () => new ApiError(404, "not_found", "no such device");

export function registerKeyWrapRoutes(app: Hono, deps: IngestDeps): void {
  app.get("/v1/devices/:id/pseudonym-key-wrap", async (c) => {
    const p = await authenticateDevice(c, deps);
    if (c.req.param("id") !== p.deviceId) throw NOT_FOUND();
    const out = await withTenant(deps.pool, p.ctx, async (tx) => {
      const own = (await tx.query<{ wrapped_key: string; wrapped_by_device_id: string | null; method: string }>(
        "select wrapped_key, wrapped_by_device_id, method from pseudonym_key_wraps where device_id = $1", [p.deviceId],
      )).rows[0];
      if (own) return own;
      // A new device has no wrap yet: it gets the recovery copy (if the tenant has one) to unwrap with the recovery code.
      const rec = (await tx.query<{ recovery_wrap: string }>(
        "select recovery_wrap from pseudonym_key_wraps where recovery_wrap is not null order by created_at, device_id limit 1",
      )).rows[0];
      return { recovery_wrap: rec?.recovery_wrap ?? null };
    });
    c.header("cache-control", "no-store");
    return c.json(out);
  });

  app.put("/v1/devices/:id/pseudonym-key-wrap", async (c) => {
    const p = await authenticateDevice(c, deps);
    if (c.req.param("id") !== p.deviceId) throw NOT_FOUND();
    const type = (c.req.header("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
    if (type !== "application/json") throw invalidRequest("content-type must be application/json");
    let body: unknown;
    try {
      body = JSON.parse(await c.req.text());
    } catch {
      throw invalidRequest("body is not JSON");
    }
    if (typeof body !== "object" || body === null || Array.isArray(body)) throw invalidRequest("body must be an object");
    const b = body as Record<string, unknown>;
    const allowed = new Set(["wrapped_key", "wrapped_by_device_id", "method", "recovery_wrap"]);
    if (Object.keys(b).some((k) => !allowed.has(k))) throw invalidRequest("unknown field");
    const { wrapped_key: wrappedKey, method, recovery_wrap: recovery } = b;
    const by = b["wrapped_by_device_id"] ?? null;
    if (typeof wrappedKey !== "string" || !WRAP_RE.test(wrappedKey)) throw invalidRequest("wrapped_key is required");
    if (method !== "device" && method !== "recovery_code") throw invalidRequest("method is device or recovery_code");
    if (by !== null && (typeof by !== "string" || !UUID_RE.test(by))) throw invalidRequest("wrapped_by_device_id is a device id or null");
    if (recovery !== undefined && (typeof recovery !== "string" || !WRAP_RE.test(recovery))) throw invalidRequest("recovery_wrap is ciphertext text");
    if (method === "device" && (by === null || by === p.deviceId)) throw invalidRequest("method device needs the wrapping device's id");
    if (method === "recovery_code" && by !== null) throw invalidRequest("method recovery_code has no wrapping device");
    await withTenant(deps.pool, p.ctx, async (tx) => {
      if (by) {
        const wrapper = (await tx.query("select 1 from devices where id = $1 and revoked_at is null", [by])).rows[0];
        if (!wrapper) throw invalidRequest("wrapped_by_device_id is not a device of this tenant");
      }
      if (recovery !== undefined) {
        // The recovery copy exists once per tenant, from the first device.
        const other = (await tx.query("select 1 from pseudonym_key_wraps where recovery_wrap is not null and device_id <> $1 limit 1", [p.deviceId])).rows[0];
        if (other) throw invalidRequest("recovery_wrap comes from the first device only");
      }
      await tx.query(
        `insert into pseudonym_key_wraps (tenant_id, device_id, wrapped_key, wrapped_by_device_id, method, recovery_wrap)
         values ($1, $2, $3, $4, $5, $6)
         on conflict (tenant_id, device_id) do update set wrapped_key = excluded.wrapped_key,
           wrapped_by_device_id = excluded.wrapped_by_device_id, method = excluded.method,
           recovery_wrap = coalesce(excluded.recovery_wrap, pseudonym_key_wraps.recovery_wrap)`,
        [p.tenantId, p.deviceId, wrappedKey, by ?? null, method, recovery ?? null],
      );
    });
    return c.body(null, 204);
  });
}
