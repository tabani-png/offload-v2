# 0033. Connector resolution pinned at design time; launch catalog

Status: accepted · Date: 2026-11-14

## Context
The connector chain resolved MCP → Composio → API → browser at run time, so an artifact verified against one adapter's
shapes could run against another. There was no launch catalog, and "MCP first" is not available from a server for
the tools that matter: Gmail, Calendar and Sheets restricted scopes need Google verification and a yearly assessment;
Slack, GitHub and Asana MCP servers need a registered app and secret (PR #42 A§10.3-10.4, R§2.10, R§3.9). Composio's
constraints from PR #42 were dropped (review-c P1(3)).

## Decision
- **Pinned at design time.** The brief names, per step: `connection_id`, adapter (`mcp`, `composio`, `openapi`,
  `browser`), tool name and **tool pin hash** = `sha256(JCS({ name, description, input_schema }))` of the tool as listed
  at design time (`connection_tool_pins`). The runtime never re-resolves.
- Before each run the runtime re-lists the pinned tools. A changed pin, a changed adapter or a removed connection puts
  the routine in state **`needs_review`** (paused, no commits). The user rebuilds (routine repair) or re-approves the
  new definition. Tool annotations such as `readOnlyHint` are never used for decisions; the capability allowlist is.
- **Launch catalog** (methods per app; each line is verified in spike S5 before it is relied on):

  | App | Method | Why |
  |---|---|---|
  | Gmail, Google Calendar, Google Sheets, Google Drive | His own Google Cloud OAuth client marked Internal to his Workspace (operator item O5); Composio for any other user until Offload has a verified client | Internal clients need no Google verification but serve only users in that Workspace (tenant of one). Restricted scopes for external users need verification and a yearly assessment (PR #42 R§2.10, R§3.9) |
  | Slack | Composio | Slack's MCP server needs a published or internal app and a client secret (PR #42 A§10.4) |
  | Notion | First-party remote MCP | PR #42 A§10.4 |
  | Linear | First-party remote MCP | PR #42 A§10.4 |
  | Stripe | Direct API (OpenAPI) with a restricted read key; MCP if S5 confirms it | Read-only payouts for the first hand-fed task ([OQ-22](../OPEN_QUESTIONS.md#oq-22-your-first-hand-fed-task-and-top-admin-drains)) |
  | QuickBooks, Xero | Composio | No direct client yet |

- **Composio constraints** (PR #42 A§10.4): the Composio API key lives only in the broker; Composio `user_id` is the
  opaque member uuid, never an email; every session has an explicit toolkit and tool allowlist; Composio meta tools
  (search, multi-execute, remote workbench, remote bash, proxy execute) are never exposed; the broker calls Composio's
  REST API v3.1 directly, no Composio SDK in the runtime. **Disclosure**: by default Composio keeps tool arguments and
  results in execution logs for up to a year; its zero-retention option is a paid add-on. That is stated in
  [SECURITY_PRIVACY.md](../SECURITY_PRIVACY.md#10-sub-processors), and enabling it is operator item O9 before any
  second user.
- The fix designer prefers MCP, then Composio, then direct API, then browser ([ADR 0010](0010-mcp-first-connectors.md)),
  filtered by what the catalog says works for this tenant.

## Consequences
- What was verified is what runs. Tool changes by a provider pause routines instead of silently changing behaviour.
- For the tenant of one, Google apps need no third party in the path.
- Composio is never required in code; in practice users outside his Workspace need it for Google apps until Offload
  has a verified OAuth client.

## Alternatives considered
- Run-time resolution (the previous version): verified shapes may differ from run shapes.
- Composio for everything on day one: simpler, but puts every call of the tenant of one through a service that logs
  payloads by default.

## Sources
Review-c P1(3); PR #42 A§10.3, A§10.4, A§10.5; old `brain/src/connectors/{catalog,mcp-probe}.ts`.
