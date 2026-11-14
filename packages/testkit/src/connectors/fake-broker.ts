import { randomBytes } from "node:crypto";
import { sha256Hex } from "@offload/contracts";
import { insideTransaction } from "@offload/db";
import type {
  BrokerPort, ListToolsInput, OAuthBeginInput, OAuthFinishInput, OAuthFinishResult, PutApiKeyInput, RawTool,
} from "@offload/connectors-sdk/src/broker-port.ts";

/**
 * FakeBroker: a BrokerPort for tests (m2-02). Records every call as given (so a test can check that an api key reached
 * the broker), never returns a token, and makes no network call. A call made inside withTenant or withTransaction is
 * recorded and then rejected, so a route that calls the broker inside a transaction fails loudly (ADR 0013).
 */

export type BrokerMethod = "oauthBegin" | "oauthFinish" | "putApiKey" | "listTools" | "shred";

export interface BrokerCall {
  method: BrokerMethod;
  input: unknown;
  insideTransaction: boolean;
}

export class BrokerInTransactionError extends Error {
  readonly code = "broker_in_transaction";
  constructor(method: string) {
    super(`FakeBroker.${method} called inside a transaction`);
    this.name = "BrokerInTransactionError";
  }
}

export class FakeBrokerError extends Error {
  readonly code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
    this.name = "FakeBrokerError";
  }
}

export const DEFAULT_FAKE_TOOLS: RawTool[] = [
  {
    name: "list_items",
    description: "Lists items.",
    input_schema: { type: "object", properties: { limit: { type: "integer" } } },
    annotations: { readOnlyHint: true },
  },
  {
    name: "create_item",
    description: "Creates an item.",
    input_schema: { type: "object", properties: { title: { type: "string" } }, required: ["title"] },
    annotations: { readOnlyHint: false },
  },
];

interface Pending {
  tenant_id: string;
  connection_id: string;
  provider: string;
  scopes: string[];
}

export class FakeBroker implements BrokerPort {
  readonly calls: BrokerCall[] = [];
  private readonly pending = new Map<string, Pending>();
  private readonly providers = new Map<string, string>();
  private readonly tools = new Map<string, RawTool[]>();
  private labels = 0;

  /** Tools listed for a connection id or, failing that, for the connection's provider slug. */
  setTools(providerOrConnectionId: string, tools: RawTool[]): void {
    this.tools.set(providerOrConnectionId, structuredClone(tools));
  }

  private readonly failures = new Map<BrokerMethod, number>();
  private readonly hooks = new Map<BrokerMethod, (input: unknown) => void | Promise<void>>();

  /** Test switch: the next `times` calls of `method` are recorded and then reject with FakeBrokerError broker_failed. */
  failNext(method: BrokerMethod, times = 1): void {
    this.failures.set(method, (this.failures.get(method) ?? 0) + times);
  }

  /** Test switch: runs `hook` once, on the next call of `method`, after recording it and before answering. */
  onNext(method: BrokerMethod, hook: (input: unknown) => void | Promise<void>): void {
    this.hooks.set(method, hook);
  }

  private async record(method: BrokerMethod, input: unknown): Promise<void> {
    const inside = insideTransaction();
    this.calls.push({ method, input, insideTransaction: inside });
    if (inside) throw new BrokerInTransactionError(method);
    const hook = this.hooks.get(method);
    if (hook) {
      this.hooks.delete(method);
      await hook(input);
    }
    const left = this.failures.get(method) ?? 0;
    if (left > 0) {
      this.failures.set(method, left - 1);
      throw new FakeBrokerError("broker_failed", `FakeBroker.${method} failed (test switch)`);
    }
  }

  async oauthBegin(input: OAuthBeginInput): Promise<{ authorize_url: string }> {
    await this.record("oauthBegin", input);
    const state = randomBytes(32).toString("base64url");
    this.pending.set(state, { tenant_id: input.tenant_id, connection_id: input.connection_id, provider: input.provider, scopes: [...input.scopes] });
    this.providers.set(input.connection_id, input.provider);
    return { authorize_url: `https://auth.broker.test/authorize?state=${state}` };
  }

  async oauthFinish(input: OAuthFinishInput): Promise<OAuthFinishResult> {
    await this.record("oauthFinish", input);
    const p = this.pending.get(input.state);
    if (!p || p.tenant_id !== input.tenant_id) throw new FakeBrokerError("state_unknown", "unknown or used state");
    this.pending.delete(input.state);
    this.labels += 1;
    return {
      connection_id: p.connection_id,
      account_label: `account-${this.labels}@example.test`,
      account_hash: sha256Hex(`fake-account:${p.connection_id}`),
      scopes: p.scopes,
    };
  }

  async putApiKey(input: PutApiKeyInput): Promise<{ account_label: string; account_hash: string }> {
    await this.record("putApiKey", input);
    this.labels += 1;
    return { account_label: `api-key-account-${this.labels}`, account_hash: sha256Hex(`fake-key-account:${input.connection_id}`) };
  }

  async listTools(input: ListToolsInput): Promise<RawTool[]> {
    await this.record("listTools", input);
    const byId = this.tools.get(input.connection_id);
    if (byId) return structuredClone(byId);
    const provider = this.providers.get(input.connection_id);
    const byProvider = provider ? this.tools.get(provider) : undefined;
    return structuredClone(byProvider ?? DEFAULT_FAKE_TOOLS);
  }

  async shred(input: { tenant_id: string; connection_id: string }): Promise<void> {
    await this.record("shred", input);
  }
}
