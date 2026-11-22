// Connector resolution for proposed fixes (ADR 0033, ADR 0010): MCP, then Composio, then a direct API, then the browser.
// LAUNCH_CATALOG is ADR 0033's launch catalog as data (the methods each app is reached by). A tenant filter (the
// verified catalog of m2-02, or the tenant of one's own Google client) removes methods. This only proposes: pinning
// a connection, tool and pin hash is the fix designer's job (m2-05).
import type { Adapter, ConnectorChoice, System, TenantCatalog } from "./types.ts";

export const ADAPTER_ORDER: readonly Adapter[] = ["mcp", "composio", "openapi", "browser"];

export interface CatalogApp {
  provider: string;
  label: string;
  /** Bare hosts of the app's web surface. */
  hosts: readonly string[];
  /** Bundle ids of its desktop apps. */
  apps: readonly string[];
  /** Methods the launch catalog lists, in ADAPTER_ORDER. */
  methods: readonly Adapter[];
}

// Google apps: his own internal OAuth client (direct API) for the tenant of one, Composio for anyone else.
export const LAUNCH_CATALOG: readonly CatalogApp[] = [
  { provider: "gmail", label: "Gmail", hosts: ["mail.google.com"], apps: [], methods: ["composio", "openapi"] },
  { provider: "google_calendar", label: "Google Calendar", hosts: ["calendar.google.com"], apps: [], methods: ["composio", "openapi"] },
  { provider: "google_sheets", label: "Google Sheets", hosts: ["sheets.google.com"], apps: [], methods: ["composio", "openapi"] },
  // docs.google.com serves Docs and Sheets alike (no URL path reaches the cloud): the Drive connector covers both.
  { provider: "google_drive", label: "Google Drive", hosts: ["docs.google.com", "drive.google.com"], apps: [], methods: ["composio", "openapi"] },
  { provider: "slack", label: "Slack", hosts: ["app.slack.com"], apps: ["com.tinyspeck.slackmacgap"], methods: ["composio"] },
  { provider: "notion", label: "Notion", hosts: ["www.notion.so", "notion.so"], apps: ["notion.id"], methods: ["mcp"] },
  { provider: "linear", label: "Linear", hosts: ["linear.app"], apps: ["com.linear"], methods: ["mcp"] },
  { provider: "stripe", label: "Stripe", hosts: ["dashboard.stripe.com"], apps: [], methods: ["openapi"] },
  { provider: "quickbooks", label: "QuickBooks", hosts: ["qbo.intuit.com", "app.qbo.intuit.com"], apps: [], methods: ["composio"] },
  { provider: "xero", label: "Xero", hosts: ["go.xero.com"], apps: [], methods: ["composio"] },
];

/** Names of common desktop apps, for option text only (bundle ids stay the system ids). */
const APP_LABELS: Readonly<Record<string, string>> = {
  "com.apple.mail": "Mail",
  "com.microsoft.Outlook": "Outlook",
  "com.microsoft.Excel": "Microsoft Excel",
  "com.microsoft.Word": "Microsoft Word",
  "com.apple.iWork.Numbers": "Numbers",
  "com.apple.iWork.Pages": "Pages",
  "com.apple.iCal": "Calendar",
  "com.apple.finder": "Finder",
  "com.apple.Preview": "Preview",
};

const ALLOW_ALL: TenantCatalog = { allows: () => true };

export function catalogAppOf(system: System): CatalogApp | undefined {
  return LAUNCH_CATALOG.find((a) => (system.surface === "web" ? a.hosts.includes(system.id) : a.apps.includes(system.id)));
}

/** A label for option text: the catalog's, a known desktop app's name, or the host / bundle id itself. */
export function labelOf(system: System): string {
  return catalogAppOf(system)?.label ?? APP_LABELS[system.id] ?? system.id;
}

/**
 * The first method in ADAPTER_ORDER that the catalog lists for the app and the tenant allows. A web app with no such
 * method goes through the browser (on the device, attended: ARCHITECTURE section 12); a desktop app with none has no
 * connector and runs on the device through the actuator.
 */
export function resolveConnector(system: System, catalog: TenantCatalog = ALLOW_ALL): ConnectorChoice {
  const app = catalogAppOf(system);
  const label = labelOf(system);
  const provider = app?.provider ?? null;
  for (const adapter of ADAPTER_ORDER) {
    if (adapter === "browser") break;
    if (app !== undefined && app.methods.includes(adapter) && catalog.allows(app.provider, adapter)) return { provider, label, adapter, runs_on: "cloud" };
  }
  if (system.surface === "web") return { provider, label, adapter: "browser", runs_on: "device" };
  return { provider, label, adapter: null, runs_on: "device" };
}
