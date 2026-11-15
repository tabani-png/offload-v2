import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomBytes } from "node:crypto";
import type { Pool } from "pg";
import { uuidv7, withTenant } from "@offload/db";
import { sha256Hex } from "@offload/contracts";
import type { KeyProvider } from "@offload/contracts/src/broker/index.ts";
import { FakeClock } from "@offload/testkit/src/auth.ts";
import { pgTenantFixture, type FixtureTenant, type PgTenantFixture } from "@offload/testkit/src/pg.ts";
import {
  FakeKms, brokerClient, brokerPool, ensureBrokerRole, fakeApprovals, fakeOAuthServer, fakeRunScope, fakeUpstream,
  type FakeApprovals, type FakeOAuthServer, type FakeRunScope, type FakeUpstream,
} from "@offload/testkit/src/broker/index.ts";
import { createBroker, type Broker } from "../../src/broker.ts";
import { awsKmsKeyProvider } from "../../src/keys/aws-kms.ts";
import { localKeyProvider } from "../../src/keys/local.ts";
import { createLogger } from "../../src/log.ts";
import type { ProviderTable } from "../../src/egress/hosts.ts";

export const SERVICE_TOKEN = "test-service-token-0123456789abcdef";
export const CLIENT_SECRET = "test-client-secret-zyxwvu";
export const COMPOSIO_KEY = "test-composio-key-abc123";

export interface Env {
  fx: PgTenantFixture;
  pool: Pool;
  kms: FakeKms;
  keys: KeyProvider;
  upstream: FakeUpstream;
  oauth: FakeOAuthServer;
  clock: FakeClock;
  scope: FakeRunScope;
  approvals: FakeApprovals;
  logs: string[];
  broker: Broker;
  socket: string;
  call: ReturnType<typeof brokerClient>;
  dir: string;
  /** Every reply text the broker produced through `call`, for canary searches. */
  replies: string[];
  stop(): Promise<void>;
}

export function writeKeyFile(dir: string, bytes: Buffer = randomBytes(32), mode = 0o600, name = "master.key"): string {
  const path = join(dir, name);
  writeFileSync(path, bytes);
  chmodSync(path, mode);
  return path;
}

export async function setup(opts: { keys?: "local" | "kms"; clock?: FakeClock } = {}): Promise<Env> {
  await ensureBrokerRole();
  const fx = await pgTenantFixture();
  const pool = brokerPool();
  const upstream = fakeUpstream();
  const oauth = fakeOAuthServer();
  const kms = new FakeKms("fake-key-id");
  const dir = mkdtempSync(join(tmpdir(), "offload-broker-"));
  const keys = opts.keys === "kms" ? awsKmsKeyProvider(kms, "fake-key-id") : localKeyProvider(writeKeyFile(dir));
  const clock = opts.clock ?? new FakeClock();
  const logs: string[] = [];
  const providers: ProviderTable = {
    stripe: { hosts: [upstream.host], allowHttp: true, auth: { header: "authorization", scheme: "bearer" } },
    google_sheets: {
      hosts: [upstream.host], allowHttp: true, auth: { header: "authorization", scheme: "bearer" },
      oauth: {
        authorizeUrl: oauth.authorizeUrl, tokenUrl: oauth.tokenUrl, userinfoUrl: oauth.userinfoUrl, clientId: "test-client-id",
        clientSecret: CLIENT_SECRET, allowHttp: true,
      },
    },
    notion: { hosts: [upstream.host], allowHttp: true, auth: { header: "authorization", scheme: "bearer" }, mcpToolsUrl: `http://${upstream.host}/mcp` },
  };
  const scope = fakeRunScope();
  const approvals = fakeApprovals();
  const broker = createBroker({
    pool, keys, clock, scope, approvals, providers, serviceToken: SERVICE_TOKEN, logger: createLogger((line) => logs.push(line)),
    composio: { apiKey: COMPOSIO_KEY, hosts: [upstream.host], allowHttp: true }, leaseWaitMs: 80,
  });
  const socket = join(dir, "broker.sock");
  const running = await broker.listen(socket);
  const client = brokerClient(socket, SERVICE_TOKEN);
  const replies: string[] = [];
  const call: Env["call"] = async (path, body, headers) => {
    const r = await client(path, body, headers);
    replies.push(r.text);
    return r;
  };
  return {
    fx, pool, kms, keys, upstream, oauth, clock, scope, approvals, logs, broker, socket, call, dir, replies,
    stop: async () => {
      await running.stop();
      await Promise.allSettled([pool.end(), fx.close(), upstream.stop(), oauth.stop()]);
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

/** Inserts a connection row for `t` (as offload_app, like the API does) and returns its id. */
export async function connect(
  env: Env, t: FixtureTenant, o: { adapter?: string; provider?: string; member?: string } = {},
): Promise<string> {
  const id = uuidv7();
  const member = o.member ?? t.owner;
  await withTenant(env.fx.app, env.fx.ctx(t, member), (tx) =>
    tx.query(
      `insert into connections (tenant_id, id, workspace_id, member_id, adapter, provider, account_label, capabilities, account_hash)
       values ($1, $2, $3, $4, $5, $6, 'Test', '{}', $7)`,
      [t.tenantId, id, t.workspaceId, member, o.adapter ?? "openapi", o.provider ?? "stripe", sha256Hex(id)],
    ),
  );
  return id;
}

export async function connectionState(env: Env, t: FixtureTenant, id: string): Promise<string> {
  return (await env.fx.admin.query("select state from connections where tenant_id = $1 and id = $2", [t.tenantId, id])).rows[0].state;
}

export async function credentialRow(env: Env, t: FixtureTenant, id: string): Promise<any> {
  return (await env.fx.admin.query("select * from credentials where tenant_id = $1 and connection_id = $2", [t.tenantId, id])).rows[0];
}

export async function auditActions(env: Env, t: FixtureTenant): Promise<{ action: string; details: any }[]> {
  return (await env.fx.admin.query("select action, details from audit_events where tenant_id = $1 order by seq", [t.tenantId])).rows;
}

/** A /call body for a read of `capability` against the fake upstream. */
export function readCall(env: Env, t: FixtureTenant, connectionId: string, capability: string, extra: Record<string, unknown> = {}) {
  return {
    tenant_id: t.tenantId, kind: "read", gate_mode: "live", connection_id: connectionId, capability, arguments: { q: "x" },
    request: { method: "GET", url: `http://${env.upstream.host}/v1/things`, headers: {}, body: null }, ...extra,
  };
}

export function commitCall(env: Env, t: FixtureTenant, connectionId: string, args: unknown, extra: Record<string, unknown> = {}) {
  return {
    tenant_id: t.tenantId, kind: "commit", gate_mode: "live", connection_id: connectionId, capability: "payout.create", arguments: args,
    approval_id: uuidv7(),
    request: { method: "POST", url: `http://${env.upstream.host}/v1/payouts`, headers: { "content-type": "application/json" }, body: JSON.stringify(args) },
    ...extra,
  };
}
