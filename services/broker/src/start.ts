import { readFileSync } from "node:fs";
import { Pool } from "pg";
import type { ApprovalVerifier, RunScopeSource } from "@offload/contracts/src/broker/index.ts";
import { createBroker } from "./broker.ts";
import { DEFAULT_COMPOSIO_HOSTS, defaultProviders } from "./egress/hosts.ts";
import { loadKeyProvider } from "./keys/index.ts";
import { createLogger } from "./log.ts";

/** Reads a secret from the file a *_REF variable names. The value is never logged. */
function readRef(path: string | undefined, what: string): string {
  if (!path) throw new Error(`${what} is required`);
  return readFileSync(path, "utf8").trim();
}

const ROLE_RE = /^[a-z_][a-z0-9_]{0,62}$/;

/**
 * Starts the broker from its environment (names in .env.example). Order matters: the key provider is checked before
 * anything listens, so a bad master key file means the process never opens the socket.
 *
 * `scope` and `approvals` are the Postgres implementations that land with the tables they read (m2-04, m2-06, m2-10);
 * until then the process refuses every read and commit (fail closed).
 */
export async function startFromEnv(
  env: Record<string, string | undefined> = process.env,
  ports?: { scope?: RunScopeSource; approvals?: ApprovalVerifier },
) {
  const keys = await loadKeyProvider(env);
  const serviceToken = readRef(env["OFFLOAD_BROKER_SERVICE_TOKEN_REF"], "OFFLOAD_BROKER_SERVICE_TOKEN_REF");
  if (serviceToken.length < 16) throw new Error("the broker service token is too short");
  const socket = env["OFFLOAD_BROKER_SOCKET"];
  if (!socket) throw new Error("OFFLOAD_BROKER_SOCKET is required");
  const databaseUrl = env["DATABASE_URL"];
  if (!databaseUrl) throw new Error("DATABASE_URL is required");
  const clientId = env["OFFLOAD_GOOGLE_CLIENT_ID"];
  const secretRef = env["OFFLOAD_GOOGLE_CLIENT_SECRET_REF"];
  const google = clientId && secretRef ? { clientId, clientSecret: readRef(secretRef, "OFFLOAD_GOOGLE_CLIENT_SECRET_REF") } : null;
  const composioKey = env["COMPOSIO_API_KEY"];

  const pool = new Pool({ connectionString: databaseUrl, max: 10 });
  const role = env["DATABASE_APP_ROLE"];
  if (role) {
    if (!ROLE_RE.test(role)) throw new Error("DATABASE_APP_ROLE is not a valid role name");
    pool.on("connect", (c) => void c.query(`set role ${role}`));
  }
  const refusingScope: RunScopeSource = { readSet: async () => null, fixtureScope: async () => null };
  const refusingApprovals: ApprovalVerifier = { check: async () => "forbidden" };
  const broker = createBroker({
    pool, keys, clock: { now: () => new Date() }, scope: ports?.scope ?? refusingScope, approvals: ports?.approvals ?? refusingApprovals,
    providers: defaultProviders(google), serviceToken, logger: createLogger(),
    composio: composioKey ? { apiKey: composioKey, hosts: DEFAULT_COMPOSIO_HOSTS } : null,
  });
  const running = await broker.listen(socket);
  return { broker, stop: async () => { await running.stop(); await pool.end(); } };
}
