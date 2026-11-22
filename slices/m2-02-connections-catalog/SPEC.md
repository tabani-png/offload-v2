---
id: m2-02-connections-catalog
title: Connections API, the launch catalog as data, capabilities, and connection pins (tool pin hashes stored at connect, compared before a run)
milestone: M2
status: done
depends_on: [m1-02-contracts-ingest, m1-03-tenancy-rls, m1-04-login-devices, m1-05-routine-contract]
parallel_safe: true
human_gated: true
model_tier: sonnet
size: M
parallel_group: M2-A
owns: [packages/connectors-sdk/**, services/api/src/connections/**, services/api/src/app.ts, packages/contracts/src/connections/**, packages/contracts/scripts/gen-json-schema.ts, packages/contracts/schemas/**, packages/db/migrations/0200_connections.sql, packages/testkit/src/connectors/**, docs/API.md]
verify: bash slices/m2-02-connections-catalog/verify.sh
min_tests: 21
paths_in_scope: [packages/connectors-sdk/**, services/api/src/connections/**, services/api/src/app.ts, services/api/tests/m2-02-connections-catalog/**, packages/contracts/src/connections/**, packages/contracts/scripts/gen-json-schema.ts, packages/contracts/schemas/**, packages/db/migrations/0200_connections.sql, packages/testkit/src/connectors/**, slices/m2-02-connections-catalog/**, docs/API.md, package.json, bun.lock, services/api/package.json, packages/testkit/package.json, packages/testkit/src/pg.ts]
paths_out_of_scope: [ee/**, apps/**, services/broker/**, services/brain/**, services/builder/**, services/runtime/**, services/api/src/ingest/**, services/api/src/audit/**, packages/masking/**, packages/db/src/**, packages/contracts/src/index.ts, packages/testkit/src/index.ts, docs/adr/**]
red_tests: [CONNECTION, CATALOG, PIN, CAPABILITY, COMPOSIO]
---

# m2-02-connections-catalog

## Summary
The connector half of the [M2 hand-fed loop](../../docs/ROADMAP.md#m2-hand-fed-loop) that does not hold secrets:
connection records, the launch catalog as data, the capability list, and connection pins. Implements
[ADR 0033](../../docs/adr/0033-pinned-connector-resolution-and-launch-catalog.md) (resolution pinned at design time,
launch catalog, Composio constraints), the connector port of [ADR 0010](../../docs/adr/0010-mcp-first-connectors.md),
[ARCHITECTURE section 10](../../docs/ARCHITECTURE.md#10-connector-and-tool-layer), the `connections` and
`connection_tool_pins` tables in [DATA_MODEL section 8](../../docs/DATA_MODEL.md#8-connectors-governance-measurement-privacy)
and the routes in [API.md, Connections](../../docs/API.md#connections-core).

Every secret (OAuth client secret, tokens, the Stripe restricted key, the Composio API key) stays in the broker
([ADR 0034](../../docs/adr/0034-credential-broker-and-key-providers.md), slice
[m2-03](../m2-03-credential-broker/SPEC.md)). This slice talks to the broker only through a `BrokerPort` interface it
defines, with a fake in `packages/testkit/src/connectors/`. The real broker client is wired in m2-04 (fixture capture),
which depends on both slices. That keeps m2-02 and m2-03 parallel.

`human_gated: true`: every catalog entry starts **unverified** and the fix designer may use only verified entries.
Spike S5 ([ROADMAP spikes](../../docs/ROADMAP.md#spikes)) is run with the owner on his accounts (operator items O5,
and O9 if a Composio app is used) and flips the entries it confirms. Without S5 the slice is complete but no app is
available to the first hand-fed task ([OQ-22](../../docs/OPEN_QUESTIONS.md#oq-22-your-first-hand-fed-task-and-top-admin-drains),
default: Stripe payouts into a Google Sheet).

Ports from the old repo ([MIGRATION section 2.6](../../docs/MIGRATION.md#26-brain-bun--ts--services-packages)):
`connectors/{chain,targets,capabilities}.ts` are **keep** (chain order and capability vocabulary) and
`connectors/{catalog,connections,mcp-probe,methods}.ts` are **rewrite** (catalog becomes data). These are from old
`main`, not from PRs #43 to #45, and need the relicensing default of
[OQ-12](../../docs/OPEN_QUESTIONS.md#oq-12-relicensing-code-from-the-old-repo). `connectors/link.ts` and the legacy `via`
field are dropped.

## Contract
- Delete `packages/connectors-sdk/tests/smoke.test.ts` and replace the TODO marker in
  `packages/connectors-sdk/src/index.ts` (first slice in this package).
- No new dependency. Uses `zod` and `@offload/contracts` (`jcs`, `sha256Hex`) as pinned by m1-02, `hono` as pinned by
  m1-04, `pg` as pinned by m1-01.
- **Shared files in M2-A** ([AGENTS.md](../../AGENTS.md#slice-format)): this slice owns the API composition root
  `services/api/src/app.ts` (one mount line for its routes; if m1-04 named the file differently, use that file and
  record it under "Scope changes"), the JSON Schema generator and `packages/contracts/schemas/**`. It does not edit the
  package barrels `packages/contracts/src/index.ts` or `packages/testkit/src/index.ts`: import new modules by subpath
  (`@offload/contracts/src/connections/index.ts`). m3-01 runs at the same time in M3-A and also mounts routes in the
  composition root; the second to land rebases.
- **Contracts** (`packages/contracts/src/connections/`, zod, exported to JSON Schema 2020-12 by the existing generator,
  `additionalProperties: false`):
  - `Adapter = "mcp" | "composio" | "openapi" | "browser"`.
  - `CatalogMethod = "google_internal" | "composio" | "mcp" | "openapi"`.
  - `CatalogEntry { app, provider, method, adapter, scopes[], capabilities[], s5_verified_at: string | null }`.
  - `Connection { connection_id, workspace_id, member_id | null, adapter, provider, account_label, capabilities[],
    state: "active" | "needs_reauth" | "revoked", created_at }` (no `external_ref`, no `account_hash` on the wire).
  - `ConnectionCreate { adapter, provider, workspace_id, personal: boolean, api_key?: string }`. `api_key` is accepted
    only for `method: "openapi"` (Stripe restricted key), is write-only and is passed straight to `BrokerPort.putApiKey`;
    it is never stored, logged or echoed by the API.
  - `ConnectionCreated { connection_id, authorize_url? }`, `ToolPinList { tools: [{ name, pin_hash }] }`,
    `Capability { name, step_class: "read" | "draft" | "commit", argument_schema, commit_arguments_allowlist? }`.
- **Migration** `packages/db/migrations/0200_connections.sql` (M2 migrations use the `02xx` range; m2-03 has `0201`):
  `connections` and `connection_tool_pins` exactly as in DATA_MODEL section 8, tenant RLS `ENABLE` + `FORCE` with
  policy `tenant_isolation`, `offload_app` gets SELECT, INSERT, UPDATE (no DELETE: a removed connection becomes
  `revoked`). Not member-isolated (no C1, C2 or C6 data).
- **Launch catalog** (`packages/connectors-sdk/src/catalog/launch.json`, validated against `CatalogEntry` at load):
  one entry per row of the ADR 0033 table: Gmail, Google Calendar, Google Sheets, Google Drive (`google_internal`,
  adapter `openapi`, scopes from the owner's Internal client, O5); Slack (`composio`); Notion, Linear (`mcp`, first-party
  remote servers); Stripe (`openapi`, restricted read key); QuickBooks, Xero (`composio`). Every entry ships with
  `s5_verified_at: null`. `availableEntries(catalog)` returns only entries with a non-null `s5_verified_at`. Spike S5's
  result is recorded by setting the date in the file in a separate commit reviewed by the owner.
- **Capabilities** (`packages/connectors-sdk/src/capabilities.ts`): the fixed vocabulary (for example `mail.send`,
  `sheet.append`, `sheet.read`, `calendar.events`, `payouts.list`) with argument schemas and step class; commit
  capabilities carry an argument allowlist. Ported in behaviour from old `connectors/capabilities.ts`.
- **Connector port** (`packages/connectors-sdk/src/port.ts`): `ConnectorAdapter { kind, listTools(conn) }`; tool
  listing for `mcp`, `composio` and `openapi` goes through `BrokerPort.listTools` (the broker holds the token), and the
  adapter parses and normalises the result to `{ name, description, input_schema }`.
- **BrokerPort** (`packages/connectors-sdk/src/broker-port.ts`), the only way this slice reaches a secret:
  `oauthBegin({ tenant_id, connection_id, provider, scopes, redirect_uri }) → { authorize_url }`,
  `oauthFinish({ tenant_id, state, code }) → { connection_id, account_label, account_hash, scopes }`,
  `putApiKey({ tenant_id, connection_id, api_key }) → { account_label, account_hash }`,
  `listTools({ tenant_id, connection_id }) → RawTool[]`, `shred({ tenant_id, connection_id }) → void`.
  PKCE, `state` and the code exchange happen inside the broker. The fake in `packages/testkit/src/connectors/` records
  calls and never returns a token.
- **Routes** (mounted under `/v1`, session or member token per [API.md section 1](../../docs/API.md#1-conventions);
  mutations need CSRF on the web; every create accepts `Idempotency-Key`):
  - `GET /v1/catalog` → `CatalogEntry[]` (all entries, with `s5_verified_at`).
  - `GET /v1/capabilities` → `Capability[]`.
  - `GET /v1/connections` → `Connection[]`.
  - `POST /v1/connections` → for `google_internal`, `mcp` and `composio`: row with `state = "needs_reauth"`, then
    `BrokerPort.oauthBegin`, returns `{ connection_id, authorize_url }`; for `openapi`: `BrokerPort.putApiKey`, row
    `active`, returns `{ connection_id }`. An app not in the catalog, or not available (unverified), is 400
    `invalid_request`.
  - `GET /v1/connections/callback?state=&code=` (new; added to API.md by this slice): `BrokerPort.oauthFinish`, sets
    `active`, `account_label`, `account_hash`, then pins the tools (below) and redirects to the web Connections page.
  - `GET /v1/connections/{id}/tools` → `ToolPinList`.
  - `DELETE /v1/connections/{id}` → `BrokerPort.shred`, then `state = "revoked"`, 204.
  - Audit (same transaction, ids and hashes only): `connection.created`, `connection.activated`,
    `connection.revoked`, `connection.pins_recorded`.
  - No network call happens inside `withTenant`: broker calls run before or after the short transactions
    ([ADR 0013](../../docs/adr/0013-tenancy-and-rls.md)).
- **Pins** (`packages/connectors-sdk/src/pins.ts`):
  - `toolPinHash(tool) = sha256Hex(jcs({ name, description, input_schema }))`. Annotations (`readOnlyHint` and the
    rest) are not part of the hash and are never used for decisions.
  - `recordPins(tx, connection_id, tools)` writes `connection_tool_pins` (`pinned_at = now()`), replacing nothing:
    re-pinning an existing tool name is refused (pins change only through repair or re-approval).
  - `comparePins(pinned, listed, pinnedAdapter, currentAdapter) → { changed: string[], removed: string[],
    adapter_changed: boolean, needs_review: boolean }`, a pure function the runtime (m2-10) calls before each run.
- **Composio constraints** (ADR 0033): `user_id` passed to the broker is the member uuid, never an email; each
  session names an explicit toolkit and tool allowlist from the catalog; Composio meta tools (search, multi-execute,
  remote workbench, remote bash, proxy execute) are filtered out of every tool list and refused as pins.
- Tool descriptions are untrusted text: only their hash is stored; they are never logged.

## Red tests (write these first, run them, see them fail)
Folders: `packages/connectors-sdk/tests/m2-02-connections-catalog/` (pure) and
`services/api/tests/m2-02-connections-catalog/` (routes, real Postgres 17).

| Tag | Test name | Asserts |
|---|---|---|
| CONNECTION | CONNECTION: POST for a google_internal app returns the broker's authorize_url and stores the connection as needs_reauth | fake broker saw `oauthBegin` with the catalog scopes; no token in the row |
| CONNECTION | CONNECTION: the callback activates the connection with the account label and pins its tools | `state = active`; `connection_tool_pins` rows; audit `connection.activated` |
| CONNECTION | CONNECTION: an openapi api_key goes to the broker only and never into a row, a log line, an audit event or the response | canary key string searched in every table, captured logs and the response body |
| CONNECTION | CONNECTION: DELETE asks the broker to shred and marks the connection revoked | 204; `shred` called once; `state = revoked` |
| CONNECTION | CONNECTION: GET /v1/connections never returns external_ref, account_hash or any secret field | schema check against `Connection` |
| CONNECTION | CONNECTION: connections of tenant A are invisible to tenant B | RLS through the route |
| CONNECTION | CONNECTION: no broker call happens inside withTenant | the fetch guard from m1-03 plus the fake broker asserting it is called outside a transaction |
| CATALOG | CATALOG: every app in the ADR 0033 table has exactly one entry with its method and adapter | Gmail, Calendar, Sheets, Drive, Slack, Notion, Linear, Stripe, QuickBooks, Xero |
| CATALOG | CATALOG: every entry validates against CatalogEntry and ships unverified | `s5_verified_at: null` |
| CATALOG | CATALOG: availableEntries returns only entries verified in spike S5 | |
| CATALOG | CATALOG: POST for an app that is not available is 400 invalid_request | |
| PIN | PIN: toolPinHash is sha256 of the JCS of name, description and input_schema | fixed vector |
| PIN | PIN: changing readOnlyHint or any other annotation does not change the pin hash | |
| PIN | PIN: comparePins reports a changed description, a removed tool and a changed adapter as needs_review | |
| PIN | PIN: an existing pin is never overwritten | second `recordPins` for the same tool name throws |
| PIN | PIN: GET /v1/connections/{id}/tools returns the stored pins | |
| CAPABILITY | CAPABILITY: GET /v1/capabilities returns every capability with its argument schema and step class | |
| CAPABILITY | CAPABILITY: a commit capability without an argument allowlist fails to load | |
| COMPOSIO | COMPOSIO: the broker gets the member uuid as user_id, never an email | |
| COMPOSIO | COMPOSIO: meta tools are filtered from tool lists and refused as pins | each of the five meta tools |
| COMPOSIO | COMPOSIO: a Composio session names an explicit toolkit and tool allowlist | |

## Out of scope
The broker and every secret operation (m2-03); wiring the real broker client to `BrokerPort` (m2-04); fixture capture
(m2-04); choosing a connector for a fix and writing pins into the brief (fix designer, m2-05, which owns the ROADMAP
tests `PIN: the brief pins connection_id, adapter, tool and pin hash; the runtime never re-resolves` and
`CONNECT: an option whose app is not connected puts the opportunity in needs_connection`); re-listing pins before a
run and pausing the routine (runtime, m2-10, using `comparePins`); browser adapter (M6); the web Connections page
(m2-11, M8); Offload's own MCP server (M8). Running spike S5 itself (owner, with O5 and O9).

## Verify
`bash slices/m2-02-connections-catalog/verify.sh` (needs `DATABASE_URL`, Postgres 17).

## Scope changes
- Added `services/api/package.json` and `packages/testkit/package.json` to `paths_in_scope`: the workspace uses
  isolated installs, so `@offload/api` and `@offload/testkit` must declare `@offload/connectors-sdk` (`workspace:*`)
  to import it. No third-party dependency is added (`packages/connectors-sdk/package.json` declares the already pinned
  `zod` 4.6.7 and `@offload/contracts`).
- Added `packages/testkit/src/pg.ts` to `paths_in_scope`: m1-03's RLS test requires every tenant table to be seeded
  for both tenants by `seedTenantRows`, so the new `connections` and `connection_tool_pins` tables get one seeded row
  each there. No other helper in the file changes.
- `ConnectionCreate`, `CatalogEntry`: `provider` is the stable slug that names one catalog entry (`gmail`,
  `google_sheets`, `stripe`, ...) and `app` is its display name. `POST /v1/connections` finds the entry by `provider`
  and refuses an `adapter` that differs from the entry's.
- `BrokerPort.oauthBegin` and `BrokerPort.listTools` take an optional `composio: { user_id, toolkit, tools[] }` session
  for Composio connections (the COMPOSIO red tests need the session to reach the broker). The toolkit and tool
  allowlist come from code (`packages/connectors-sdk/src/composio.ts`), keyed by catalog provider and capability, so
  `CatalogEntry` keeps the exact fields above.
