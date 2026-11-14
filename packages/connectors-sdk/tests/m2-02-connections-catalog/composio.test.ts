import { expect, test } from "bun:test";
import type { CatalogEntry } from "@offload/contracts/src/connections/index.ts";
import { createAdapter, normalizeTools } from "../../src/adapters.ts";
import type {
  BrokerPort,
  ComposioSession,
  ListToolsInput,
  OAuthBeginInput,
  OAuthFinishInput,
  PutApiKeyInput,
  RawTool,
} from "../../src/broker-port.ts";
import { findEntry, launchCatalog } from "../../src/catalog/index.ts";
import { COMPOSIO_META_TOOLS, COMPOSIO_TOOLKITS, composioSession, isComposioMetaTool } from "../../src/composio.ts";
import { PinRefusedError, recordPins, type SqlTx } from "../../src/pins.ts";
import type { ConnectionRef, NormalizedTool } from "../../src/port.ts";

const MEMBER_ID = "0190a3c4-5b6d-7e8f-9a0b-1c2d3e4f5a6b";
const TENANT_ID = "0190a3c4-0000-7000-8000-000000000001";
const CONNECTION_ID = "0190a3c4-0000-7000-8000-0000000000c1";

const EXPECTED_META_TOOLS = [
  "COMPOSIO_SEARCH_TOOLS",
  "COMPOSIO_MULTI_EXECUTE_TOOL",
  "COMPOSIO_REMOTE_WORKBENCH",
  "COMPOSIO_REMOTE_BASH_TOOL",
  "COMPOSIO_PROXY_EXECUTE",
];

/** A tiny in-test broker: records listTools inputs and returns canned tools. Never holds a secret. */
class RecordingBroker implements BrokerPort {
  listed: ListToolsInput[] = [];
  constructor(private readonly tools: RawTool[]) {}
  async oauthBegin(_input: OAuthBeginInput): Promise<{ authorize_url: string }> {
    throw new Error("not used");
  }
  async oauthFinish(_input: OAuthFinishInput): Promise<never> {
    throw new Error("not used");
  }
  async putApiKey(_input: PutApiKeyInput): Promise<never> {
    throw new Error("not used");
  }
  async listTools(input: ListToolsInput): Promise<RawTool[]> {
    this.listed.push(structuredClone(input));
    return structuredClone(this.tools);
  }
  async shred(): Promise<void> {
    throw new Error("not used");
  }
}

function entry(provider: string): CatalogEntry {
  const e = findEntry(launchCatalog(), provider);
  if (!e) throw new Error(`no catalog entry ${provider}`);
  return e;
}

function raw(name: string): RawTool {
  return {
    name,
    description: `Synthetic ${name}.`,
    inputSchema: { type: "object" },
    annotations: { readOnlyHint: true },
  };
}

function ref(composio?: ComposioSession, adapter: ConnectionRef["adapter"] = "composio"): ConnectionRef {
  return {
    tenant_id: TENANT_ID,
    connection_id: CONNECTION_ID,
    adapter,
    provider: adapter === "composio" ? "slack" : "linear",
    ...(composio ? { composio } : {}),
  };
}

async function rejection(fn: () => Promise<unknown>): Promise<unknown> {
  try {
    await fn();
  } catch (err) {
    return err;
  }
  return null;
}

test("COMPOSIO: the broker gets the member uuid as user_id, never an email", async () => {
  const slack = entry("slack");
  const session = composioSession(slack, MEMBER_ID);
  expect(session.user_id).toBe(MEMBER_ID);

  expect(() => composioSession(slack, "member-1@example.test")).toThrow();
  expect(() => composioSession(slack, MEMBER_ID.toUpperCase())).toThrow();
  expect(() => composioSession(slack, "not-a-uuid")).toThrow();
  expect(() => composioSession(slack, "")).toThrow();

  const broker = new RecordingBroker([raw(session.tools[0] as string)]);
  const adapter = createAdapter("composio", broker);
  expect(adapter.kind).toBe("composio");
  await adapter.listTools(ref(session));

  expect(broker.listed).toHaveLength(1);
  const seen = broker.listed[0] as ListToolsInput;
  expect(seen.tenant_id).toBe(TENANT_ID);
  expect(seen.connection_id).toBe(CONNECTION_ID);
  expect(seen.composio?.user_id).toBe(MEMBER_ID);
  expect(seen.composio?.user_id).not.toContain("@");
  expect(seen.composio?.toolkit).toBe(session.toolkit);
  expect(seen.composio?.tools).toEqual(session.tools);
});

test("COMPOSIO: meta tools are filtered from tool lists and refused as pins", async () => {
  expect([...COMPOSIO_META_TOOLS].sort()).toEqual([...EXPECTED_META_TOOLS].sort());
  expect(isComposioMetaTool("SLACK_SEND_MESSAGE")).toBe(false);
  expect(isComposioMetaTool("composio_search_tools")).toBe(true);

  for (const meta of EXPECTED_META_TOOLS) {
    expect(isComposioMetaTool(meta)).toBe(true);

    // Filtered out of a normalised tool list.
    const normalized = normalizeTools([raw("issue_list"), raw(meta)]);
    expect(normalized.map((t) => t.name)).toEqual(["issue_list"]);

    // Filtered out of an mcp adapter's list too ("every tool list").
    const mcp = createAdapter("mcp", new RecordingBroker([raw(meta), raw("issue_list")]));
    expect((await mcp.listTools(ref(undefined, "mcp"))).map((t) => t.name)).toEqual(["issue_list"]);

    // Refused as a pin, before anything is written, even alongside an ordinary tool.
    const queries: string[] = [];
    const tx: SqlTx = {
      async query(text: string) {
        queries.push(text);
        return { rows: [], rowCount: 0 };
      },
    };
    const metaTool: NormalizedTool = { name: meta, description: "", input_schema: { type: "object" } };
    const ordinary: NormalizedTool = { name: "issue_list", description: "", input_schema: { type: "object" } };
    for (const tools of [[metaTool], [ordinary, metaTool]]) {
      const err = await rejection(() => recordPins(tx, CONNECTION_ID, tools));
      expect(err).toBeInstanceOf(PinRefusedError);
      expect((err as PinRefusedError).code).toBe("pin_refused");
      expect((err as PinRefusedError).tool).toBe(meta);
    }
    expect(queries).toHaveLength(0);
  }
});

test("COMPOSIO: a Composio session names an explicit toolkit and tool allowlist", async () => {
  for (const provider of ["slack", "quickbooks", "xero"]) {
    const e = entry(provider);
    expect(e.method).toBe("composio");
    expect(COMPOSIO_TOOLKITS[provider]).toBeDefined();

    const session = composioSession(e, MEMBER_ID);
    expect(session.toolkit.length).toBeGreaterThan(0);
    expect(session.toolkit).toBe(COMPOSIO_TOOLKITS[provider]?.toolkit as string);
    expect(session.tools.length).toBeGreaterThan(0);
    expect(session.tools).toEqual([...new Set(session.tools)].sort());
    for (const t of session.tools) expect(isComposioMetaTool(t)).toBe(false);
  }

  // Not a Composio entry.
  expect(() => composioSession(entry("gmail"), MEMBER_ID)).toThrow();
  expect(() => composioSession(entry("linear"), MEMBER_ID)).toThrow();

  // The composio adapter keeps only the session's allowlist (and never a meta tool).
  const session = composioSession(entry("slack"), MEMBER_ID);
  const allowed = session.tools[0] as string;
  const broker = new RecordingBroker([
    raw(allowed),
    raw("SLACK_NOT_ON_THE_ALLOWLIST"),
    raw("COMPOSIO_SEARCH_TOOLS"),
  ]);
  const adapter = createAdapter("composio", broker);
  const listed = await adapter.listTools(ref(session));
  expect(listed.map((t) => t.name)).toEqual([allowed]);
  expect(Object.keys(listed[0] as NormalizedTool).sort()).toEqual(["description", "input_schema", "name"]);

  // Without a session the composio adapter refuses and never reaches the broker.
  const bare = new RecordingBroker([raw(allowed)]);
  const err = await rejection(() => createAdapter("composio", bare).listTools(ref(undefined)));
  expect(err).toBeInstanceOf(Error);
  expect(bare.listed).toHaveLength(0);
});
