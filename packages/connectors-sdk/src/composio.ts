import type { CatalogEntry } from "@offload/contracts/src/connections/index.ts";
import type { ComposioSession } from "./broker-port.ts";

/**
 * Composio constraints (ADR 0033): the broker gets the member uuid as `user_id`, never an email; every session names
 * an explicit toolkit and tool allowlist; Composio meta tools are filtered from every tool list and refused as pins.
 */

/** Search, multi-execute, remote workbench, remote bash, proxy execute. */
export const COMPOSIO_META_TOOLS = [
  "COMPOSIO_SEARCH_TOOLS",
  "COMPOSIO_MULTI_EXECUTE_TOOL",
  "COMPOSIO_REMOTE_WORKBENCH",
  "COMPOSIO_REMOTE_BASH_TOOL",
  "COMPOSIO_PROXY_EXECUTE",
] as const;

/** True for the five meta tools and for any other `COMPOSIO_` tool (case-insensitive). */
export function isComposioMetaTool(name: string): boolean {
  return name.toUpperCase().startsWith("COMPOSIO_");
}

export interface ComposioToolkit {
  toolkit: string;
  /** capability name -> the Composio tool slugs that capability may use. */
  tools: Readonly<Record<string, readonly string[]>>;
}

/** Keyed by catalog provider. Tool slugs are best guesses that spike S5 confirms. */
export const COMPOSIO_TOOLKITS: Readonly<Record<string, ComposioToolkit>> = {
  slack: {
    toolkit: "SLACK",
    tools: {
      "message.post": ["SLACK_SEND_MESSAGE"],
      "channel.history": ["SLACK_FETCH_CONVERSATION_HISTORY"],
    },
  },
  quickbooks: {
    toolkit: "QUICKBOOKS",
    tools: {
      "invoice.list": ["QUICKBOOKS_LIST_INVOICES"],
      "invoice.create": ["QUICKBOOKS_CREATE_INVOICE"],
    },
  },
  xero: {
    toolkit: "XERO",
    tools: {
      "invoice.list": ["XERO_LIST_INVOICES"],
      "invoice.create": ["XERO_CREATE_INVOICE"],
    },
  },
};

const LOWER_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** The session for a member's Composio connection. Throws for a non-Composio entry or a `memberId` that is not a
 * lower-case uuid (an email is refused). */
export function composioSession(entry: CatalogEntry, memberId: string): ComposioSession {
  if (entry.method !== "composio") throw new Error(`provider ${entry.provider} is not a Composio app`);
  if (!LOWER_UUID.test(memberId)) throw new Error("composio user_id must be the member uuid");
  const kit = Object.hasOwn(COMPOSIO_TOOLKITS, entry.provider) ? COMPOSIO_TOOLKITS[entry.provider] : undefined;
  if (!kit || kit.toolkit.length === 0) throw new Error(`no Composio toolkit for provider ${entry.provider}`);
  const tools = new Set<string>();
  for (const cap of entry.capabilities) {
    const slugs = Object.hasOwn(kit.tools, cap) ? kit.tools[cap] : undefined;
    for (const slug of slugs ?? []) if (!isComposioMetaTool(slug)) tools.add(slug);
  }
  if (tools.size === 0) throw new Error(`no Composio tool allowlist for provider ${entry.provider}`);
  return { user_id: memberId, toolkit: kit.toolkit, tools: [...tools].sort() };
}
