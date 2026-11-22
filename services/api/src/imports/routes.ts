import type { Context, Hono } from "hono";
import {
  ForgetRequestSchema, OpenImportRequestSchema, type ForgetResponse, type Import, type OpenImportResponse, type PurgeRequestState,
} from "@offload/contracts";
import { appendAudit, uuidv7, withTenant, type TenantContext } from "@offload/db";
import { ApiError, invalidRequest } from "../http.ts";
import type { IngestDeps } from "../ingest/context.ts";
import { forgetImport } from "./forget.ts";

/**
 * Import spaces and forget scope `import` (docs/API.md "Profile and privacy", ADR 0020 "Imported objects", slice
 * m3-05b). Member token or web session with CSRF on POST; every query runs in withTenant for the caller, so the
 * tenant and member walls scope `imports`, `observations` and `observation_texts`.
 */

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

async function jsonBody(c: Context): Promise<unknown> {
  const type = (c.req.header("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
  if (type !== "application/json") throw invalidRequest("content-type must be application/json");
  try {
    return JSON.parse(await c.req.text());
  } catch {
    throw invalidRequest("body is not JSON");
  }
}

const notFound = (what: string) => new ApiError(404, "not_found", `no such ${what}`);

export function registerImportRoutes(app: Hono, deps: IngestDeps): void {
  async function member(c: Context): Promise<TenantContext & { memberId: string }> {
    const p = await deps.authenticateMember(c);
    return { tenantId: p.tenantId, principalId: p.memberId, memberId: p.memberId, tenantRole: p.tenantRole };
  }

  app.post("/v1/imports", async (c) => {
    const ctx = await member(c);
    const body = OpenImportRequestSchema.safeParse(await jsonBody(c));
    if (!body.success) throw invalidRequest("source_kind must be screenwatch, screenshots or videos");
    const id = uuidv7();
    await withTenant(deps.pool, ctx, async (tx) => {
      await tx.query(
        "insert into imports (tenant_id, member_id, id, source_kind, created_at) values ($1, $2, $3, $4, $5)",
        [ctx.tenantId, ctx.memberId, id, body.data.source_kind, deps.clock.now()],
      );
      await appendAudit(tx, {
        principalId: ctx.memberId, action: "import.opened", subjectType: "import", subjectId: id,
        details: { source_kind: body.data.source_kind },
      });
    });
    c.header("cache-control", "no-store");
    return c.json({ import_id: id } satisfies OpenImportResponse, 201);
  });

  app.get("/v1/imports", async (c) => {
    const ctx = await member(c);
    const rows = await withTenant(deps.pool, ctx, async (tx) =>
      (await tx.query<{ id: string; source_kind: Import["source_kind"]; first_day: string | null; last_day: string | null; created_at: Date }>(
        `select id, source_kind, first_day::text as first_day, last_day::text as last_day, created_at
           from imports where member_id = $1 and wiped_at is null order by created_at desc, id desc`,
        [ctx.memberId],
      )).rows);
    c.header("cache-control", "no-store");
    return c.json(rows.map((r): Import => ({
      id: r.id, source_kind: r.source_kind, first_day: r.first_day, last_day: r.last_day, created_at: r.created_at.toISOString(),
    })));
  });

  app.post("/v1/me/forget", async (c) => {
    const ctx = await member(c);
    const body = ForgetRequestSchema.safeParse(await jsonBody(c));
    if (!body.success) throw invalidRequest("invalid forget request");
    const b = body.data;
    // Scopes entity, range and all arrive in M7 (docs/API.md).
    if (b.scope !== "import") throw invalidRequest("only scope import is available");
    if (b.import_id === undefined || b.entity_id !== undefined || b.from !== undefined || b.to !== undefined) {
      throw invalidRequest("scope import takes import_id only");
    }
    const importId = b.import_id.toLowerCase();
    const done = await withTenant(deps.pool, ctx, (tx) =>
      forgetImport(tx, { tenantId: ctx.tenantId, memberId: ctx.memberId, importId, requestedBy: ctx.memberId, now: deps.clock.now() }));
    if (!done) throw notFound("import");
    c.header("cache-control", "no-store");
    return c.json({ purge_request_id: done.purgeRequestId } satisfies ForgetResponse, 202);
  });

  app.get("/v1/purge-requests/:id", async (c) => {
    const ctx = await member(c);
    const id = c.req.param("id");
    if (!UUID_RE.test(id)) throw notFound("purge request");
    const row = await withTenant(deps.pool, ctx, async (tx) =>
      (await tx.query<PurgeRequestState>("select state from purge_requests where id = $1 and member_id = $2", [id, ctx.memberId])).rows[0]);
    if (!row) throw notFound("purge request");
    c.header("cache-control", "no-store");
    return c.json({ state: row.state } satisfies PurgeRequestState);
  });
}
