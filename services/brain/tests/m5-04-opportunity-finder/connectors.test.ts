import { expect, test } from "bun:test";
import { ADAPTER_ORDER, LAUNCH_CATALOG, resolveConnector } from "../../src/opportunities/connectors.ts";
import type { Adapter, System } from "../../src/opportunities/types.ts";

const web = (id: string): System => ({ id, surface: "web", work_kind: "browse" });
const desktop = (id: string): System => ({ id, surface: "desktop", work_kind: "other" });

test("CONNECTOR: resolution prefers MCP, then Composio, then a direct API, then the browser", () => {
  expect(ADAPTER_ORDER).toEqual(["mcp", "composio", "openapi", "browser"]);
  // ADR 0033's launch catalog as data.
  const byProvider = new Map(LAUNCH_CATALOG.map((a) => [a.provider, a.methods]));
  expect(byProvider.get("notion")).toEqual(["mcp"]);
  expect(byProvider.get("linear")).toEqual(["mcp"]);
  expect(byProvider.get("slack")).toEqual(["composio"]);
  expect(byProvider.get("stripe")).toEqual(["openapi"]);
  expect(byProvider.get("gmail")).toEqual(["composio", "openapi"]);
  expect(resolveConnector(web("www.notion.so"))).toEqual({ provider: "notion", label: "Notion", adapter: "mcp", runs_on: "cloud" });
  expect(resolveConnector(desktop("com.tinyspeck.slackmacgap"))).toEqual({ provider: "slack", label: "Slack", adapter: "composio", runs_on: "cloud" });
  expect(resolveConnector(web("dashboard.stripe.com"))).toEqual({ provider: "stripe", label: "Stripe", adapter: "openapi", runs_on: "cloud" });
  expect(resolveConnector(web("mail.google.com"))).toEqual({ provider: "gmail", label: "Gmail", adapter: "composio", runs_on: "cloud" });
  // The tenant of one: Google apps through his own internal OAuth client, no Composio in the path.
  const ownGoogle = { allows: (p: string, a: Adapter) => !(p.startsWith("g") && a === "composio") };
  expect(resolveConnector(web("mail.google.com"), ownGoogle)).toEqual({ provider: "gmail", label: "Gmail", adapter: "openapi", runs_on: "cloud" });
});

test("CONNECTOR: a tenant filter removes methods; an unknown web app goes through the browser and an unknown desktop app runs on the device", () => {
  const noMcp = { allows: (_p: string, a: Adapter) => a !== "mcp" };
  expect(resolveConnector(web("www.notion.so"), noMcp)).toEqual({ provider: "notion", label: "Notion", adapter: "browser", runs_on: "device" });
  expect(resolveConnector(desktop("notion.id"), noMcp)).toEqual({ provider: "notion", label: "Notion", adapter: null, runs_on: "device" });
  expect(resolveConnector(web("app.ledgerly.example"))).toEqual({ provider: null, label: "app.ledgerly.example", adapter: "browser", runs_on: "device" });
  expect(resolveConnector(desktop("com.microsoft.Excel"))).toEqual({ provider: null, label: "Microsoft Excel", adapter: null, runs_on: "device" });
  expect(resolveConnector(desktop("com.example.unknown"))).toEqual({ provider: null, label: "com.example.unknown", adapter: null, runs_on: "device" });
});
