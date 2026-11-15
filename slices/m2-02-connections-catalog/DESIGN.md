# m2-02-connections-catalog: implementation design

Planned by Opus 5.5 for the SPEC in this folder. The SPEC wins where they differ. Words follow docs/GLOSSARY.md.

## Seam (already written, do not change shapes without telling the planner)
- `packages/contracts/src/connections/index.ts`: zod contracts (`CatalogEntrySchema`, `ConnectionSchema`,
  `ConnectionCreateSchema`, `ConnectionCreatedSchema`, `ToolPinListSchema`, `CapabilitySchema`, enums).
  Import by subpath `@offload/contracts/src/connections/index.ts` (never edit `packages/contracts/src/index.ts`).
- `packages/connectors-sdk/src/broker-port.ts`: `BrokerPort`, `RawTool`, `ComposioSession` and the inputs.
- `packages/connectors-sdk/src/port.ts`: `ConnectorAdapter`, `ConnectionRef`, `NormalizedTool`.

## packages/connectors-sdk (pure; no fetch, no sockets, no @offload/db import)
- `src/capabilities.ts`
  - `CAPABILITY_DEFS`: the fixed vocabulary, each `{ name, step_class, argument_schema, commit_arguments_allowlist? }`.
    `argument_schema` is a JSON Schema object (`type: "object"`, `properties`, `required`, `additionalProperties:
    false`). Vocabulary (at least): `mail.search` (read), `mail.read` (read), `mail.draft` (draft), `mail.send`
    (commit), `calendar.events` (read), `calendar.create_event` (commit), `sheet.read` (read), `sheet.append` (commit),
    `sheet.update` (commit), `drive.files` (read), `message.post` (commit), `channel.history` (read), `page.read`
    (read), `page.create` (commit), `issue.list` (read), `issue.create` (commit), `payouts.list` (read),
    `balance.read` (read), `invoice.list` (read), `invoice.create` (commit).
  - `class CapabilityLoadError extends Error` with `code = "capability_invalid"`.
  - `loadCapabilities(defs: unknown[]): Capability[]`: validates each against `CapabilitySchema`; throws
    `CapabilityLoadError` when a `commit` capability has no `commit_arguments_allowlist`, when a non-commit capability
    has one, when an allowlisted name is not a property of `argument_schema.properties`, or on a duplicate name.
  - `CAPABILITIES: readonly Capability[] = loadCapabilities(CAPABILITY_DEFS)` (loaded at import, so a bad
    definition fails the module load), `capabilityNames(): string[]`, `findCapability(name)`.
- `src/catalog/launch.json`: the ten ADR 0033 entries, every `s5_verified_at: null`.
  | app | provider | method | adapter |
  |---|---|---|---|
  | Gmail | `gmail` | google_internal | openapi |
  | Google Calendar | `google_calendar` | google_internal | openapi |
  | Google Sheets | `google_sheets` | google_internal | openapi |
  | Google Drive | `google_drive` | google_internal | openapi |
  | Slack | `slack` | composio | composio |
  | Notion | `notion` | mcp | mcp |
  | Linear | `linear` | mcp | mcp |
  | Stripe | `stripe` | openapi | openapi |
  | QuickBooks | `quickbooks` | composio | composio |
  | Xero | `xero` | composio | composio |
  Google scopes are the Google OAuth scope URLs the capabilities need (`gmail.readonly`, `gmail.compose`,
  `gmail.send`; `calendar.events`; `spreadsheets`; `drive.readonly`). Others: the provider's scope names where known,
  else `[]`. Spike S5 confirms them.
- `src/catalog/index.ts`
  - `class CatalogLoadError extends Error` with `code = "catalog_invalid"`.
  - `loadCatalog(data: unknown): CatalogEntry[]`: array of `CatalogEntrySchema`; unique `provider`; every capability in
    the vocabulary; adapter matches method (`google_internal` → `openapi`, `composio` → `composio`, `mcp` → `mcp`,
    `openapi` → `openapi`). Throws `CatalogLoadError`.
  - `launchCatalog(): CatalogEntry[]` (a fresh deep copy of the validated launch.json each call).
  - `availableEntries(catalog)`: entries with a non-null `s5_verified_at`.
  - `findEntry(catalog, provider): CatalogEntry | undefined`.
  - `methodAdapter(method): Adapter`.
- `src/composio.ts` (ADR 0033 Composio constraints)
  - `COMPOSIO_META_TOOLS = ["COMPOSIO_SEARCH_TOOLS", "COMPOSIO_MULTI_EXECUTE_TOOL", "COMPOSIO_REMOTE_WORKBENCH",
    "COMPOSIO_REMOTE_BASH_TOOL", "COMPOSIO_PROXY_EXECUTE"]` (search, multi-execute, remote workbench, remote bash,
    proxy execute).
  - `isComposioMetaTool(name)`: true for those five and for any name starting with `COMPOSIO_` (case-insensitive).
  - `COMPOSIO_TOOLKITS`: provider → `{ toolkit, tools: { [capability]: string[] } }` for `slack` (`SLACK`),
    `quickbooks` (`QUICKBOOKS`), `xero` (`XERO`). Tool slugs are best guesses that S5 confirms.
  - `composioSession(entry: CatalogEntry, memberId: string): ComposioSession`: throws unless `entry.method ===
    "composio"`, unless `memberId` is a lower-case uuid (an email or anything else is refused), and unless the toolkit
    and a non-empty tool allowlist exist for the entry's capabilities. `tools` is sorted and deduplicated and never
    contains a meta tool.
- `src/adapters.ts`
  - `normalizeTools(raw: RawTool[]): NormalizedTool[]`: keeps `{ name, description, input_schema }` only (annotations
    and every other key dropped); `input_schema` from `input_schema` or `inputSchema`, default `{ type: "object" }`;
    `description` default `""`; drops entries whose name is not a valid `toolName` or whose schema is not a plain
    object; drops every Composio meta tool; throws on two tools with the same name. Never logs a description.
  - `createAdapter(kind: "mcp" | "composio" | "openapi", broker): ConnectorAdapter`: `listTools(conn)` calls
    `broker.listTools({ tenant_id, connection_id, composio? })` and returns `normalizeTools(...)`. For `composio` the
    `conn.composio` session is required (throw without it), passed to the broker, and the result is also filtered to
    the session's `tools` allowlist.
- `src/pins.ts`
  - `toolPinHash(tool)`: `sha256Hex(jcs({ name, description, input_schema }))` from `@offload/contracts` (`jcs`,
    `sha256Hex` from the barrel are fine to import). Other keys of `tool` are ignored.
  - `interface SqlTx { query(text: string, values?: unknown[]): Promise<{ rows: any[]; rowCount: number | null }> }`
    (structurally what `@offload/db`'s `Tx` is; no import of @offload/db).
  - `class PinRefusedError extends Error` (`code = "pin_refused"`, `.tool`): a Composio meta tool.
  - `class PinExistsError extends Error` (`code = "pin_exists"`, `.tool`): the tool name already has a pin.
  - `recordPins(tx, connectionId, tools: NormalizedTool[]): Promise<ToolPin[]>`: inside the caller's withTenant
    transaction; refuses meta tools before writing anything; for each tool inserts `(tenant_id, connection_id,
    tool_name, pin_hash)` with `tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid` and
    `pinned_at = now()` (default). Never `on conflict`: an existing pin makes it throw `PinExistsError` (check with a
    select first, and also map a `23505` unique violation to `PinExistsError`). Returns the pins sorted by name.
  - `comparePins(pinned: ToolPin[], listed: NormalizedTool[], pinnedAdapter, currentAdapter)` →
    `{ changed, removed, adapter_changed, needs_review }`: `changed` = pinned names listed with a different hash,
    `removed` = pinned names not listed (sorted); newly listed tools are ignored; `needs_review` is true when any of the
    three is non-empty/true. Pure.
- `src/index.ts`: re-exports everything above (replaces the TODO marker). Delete `tests/smoke.test.ts`.
- `package.json` already declares `@offload/contracts` and `zod` 4.6.7.

## packages/contracts
- `scripts/gen-json-schema.ts`: add `catalog-entry`, `connection`, `connection-create`, `connection-created`,
  `tool-pin-list`, `capability` (import them by subpath). Add the JSON Schema rule zod cannot export: in `capability`,
  `if step_class is "commit" then commit_arguments_allowlist is required`. Regenerate `schemas/` with
  `bun packages/contracts/scripts/gen-json-schema.ts`. m1-02's CONTRACT tests check the files are fresh.

## packages/db/migrations/0200_connections.sql
`connections (tenant_id uuid not null references tenants(id), id uuid not null, workspace_id uuid not null,
member_id uuid null, adapter text check in (mcp, composio, openapi, browser), provider text check slug, account_label
text null (<= 256), capabilities text[] not null default '{}', external_ref text null, account_hash text null check
hex64, state text not null default 'needs_reauth' check in (active, needs_reauth, revoked), created_at timestamptz not
null default now(), primary key (tenant_id, id), foreign key (tenant_id, workspace_id) references workspaces
(tenant_id, id), foreign key (tenant_id, member_id) references members (tenant_id, id))` and
`connection_tool_pins (tenant_id, connection_id, tool_name text check toolName, pin_hash text check hex64,
pinned_at timestamptz not null default now(), primary key (tenant_id, connection_id, tool_name), foreign key
(tenant_id, connection_id) references connections (tenant_id, id))`. Then `select apply_tenant_rls(...)` on both
(ENABLE + FORCE + `tenant_isolation`), `grant select, insert, update on connections, connection_tool_pins to
offload_app` (no DELETE). Not member-isolated. Header comment like 0005's.

## packages/testkit
- `src/connectors/fake-broker.ts` (+ `src/connectors/index.ts`): `class FakeBroker implements BrokerPort`.
  - `calls: { method, input, insideTransaction }[]` (inputs recorded as given, so tests can assert the api key reached
    the broker; `insideTransaction()` from `@offload/db`). Any call made inside a transaction is recorded and then
    rejected with an error, so a route that calls the broker in withTenant fails loudly.
  - `oauthBegin` returns `https://auth.broker.test/authorize?state=<random 32 bytes base64url>` and remembers
    state → `{ tenant_id, connection_id }`; `oauthFinish` looks the state up (single use; wrong tenant or unknown state
    rejects), returns `{ connection_id, account_label: "account-1@example.test", account_hash: sha256 hex, scopes }`.
  - `putApiKey` returns a label and hash and keeps the key only in `calls`.
  - `listTools` returns tools set by `setTools(provider_or_connection_id, RawTool[])`, defaulting to two synthetic tools
    with annotations (`readOnlyHint`).
  - `shred` records the call. Never returns a token.
  - Import it in tests by path `@offload/testkit/src/connectors/index.ts` (do not edit `packages/testkit/src/index.ts`).
- `src/pg.ts`, `seedMember`: one `connections` row (personal, `active`, adapter `openapi`, provider `stripe`) and one
  `connection_tool_pins` row for it, so m1-03's RLS tests see rows in every tenant table. Nothing else changes.

## services/api
- `src/connections/routes.ts`: `mountConnections(app: Hono, deps: ConnectionsDeps)` where
  `ConnectionsDeps = { pool, broker?: BrokerPort, authenticate(c): Promise<{ tenantId, memberId, tenantRole, via }>,
  clock, publicBaseUrl, catalog?: CatalogEntry[] (default launchCatalog()), jsonBody(c) }`.
- `src/app.ts`: `AppDeps` gains `broker?: BrokerPort` and `catalog?: CatalogEntry[]`; one line mounts the routes,
  passing the existing `authenticate` and `jsonBody`. Without a broker, `POST /v1/connections`, the callback and
  `DELETE` answer 404 `not_found` (the m1-04 pattern for unconfigured features); the GET routes still work. m1-04
  tests must still pass untouched.
- Routes (all need a session or member token; CSRF is enforced by `authenticate` on session mutations):
  - `GET /v1/catalog` → `CatalogEntry[]` (all, with `s5_verified_at`). `GET /v1/capabilities` → `Capability[]`.
  - `GET /v1/connections` → `Connection[]` visible to the caller: workspace connections (`member_id` null) and the
    caller's own; owner and admin see every connection of the tenant. Never `external_ref`, `account_hash` or any
    secret: build each item explicitly and parse it with `ConnectionSchema` before sending.
  - `POST /v1/connections` (JSON only, `ConnectionCreateSchema`, else 400 `invalid_request`):
    the entry is `findEntry(catalog, provider)`; missing, not in `availableEntries`, or `adapter` differs → 400
    `invalid_request`. `api_key` required for method `openapi` and refused for the others (400). The workspace must
    exist in the tenant (else 400). `personal: false` needs owner or admin (else 403 `forbidden`).
    `member_id` = caller when personal, else null. `capabilities` = the entry's.
    - google_internal, mcp, composio: tx1 inserts the row `needs_reauth` + audit `connection.created`; then (outside
      any transaction) `broker.oauthBegin({ tenant_id, connection_id, provider, scopes: entry.scopes, redirect_uri:
      `${publicBaseUrl}/v1/connections/callback`, composio? })` where composio = `composioSession(entry, caller
      memberId)`; 201 `{ connection_id, authorize_url }`.
    - openapi: tx1 inserts `needs_reauth` + audit `connection.created`; `broker.putApiKey({ tenant_id, connection_id,
      api_key })`; tx2 sets `active`, `account_label`, `account_hash` + audit `connection.activated`; then the pins
      (below); 201 `{ connection_id }`. The api key is never stored, logged, audited, hashed into a row, or echoed.
    - `Idempotency-Key` (ULID): `idempotency_keys` row (`request_sha256` = sha256 of JCS of the body with `api_key`
      removed and `api_key_present: bool` added); same key + same body within 24 h → the stored status and response;
      same key + other body → 409 `idempotency_conflict`. Store `status 0` (pending) in tx1 and the final 201 response
      after the broker answered; a replay while pending is 409 `idempotency_conflict`.
  - `GET /v1/connections/callback?state=&code=` (session or member token, GET so no CSRF): `state` and `code` must
    match `^[\x21-\x7e]{1,512}$` else 400. `broker.oauthFinish({ tenant_id, state, code })` outside any transaction;
    tx: the connection must be visible to the caller and `needs_reauth` (else 404 / 409 `state_conflict`); set
    `active`, `account_label`, `account_hash` + audit `connection.activated` (`{ account_hash }`); then pins; 302 to
    `${publicBaseUrl}/connections?connection_id=<id>`.
  - Pins after activation: `createAdapter(conn.adapter, broker).listTools({ tenant_id, connection_id, adapter,
    provider, composio? })` outside a transaction, then tx: `recordPins` + audit `connection.pins_recorded`
    (`{ count, pins_hash }` where pins_hash = sha256Hex(jcs(sorted pins))).
  - `GET /v1/connections/{id}/tools` → `{ tools: [{ name, pin_hash }] }` sorted by name (404 when not visible or not a
    uuid).
  - `DELETE /v1/connections/{id}`: visible and not yet revoked → `broker.shred` (outside a transaction), then tx:
    `state = 'revoked'` + audit `connection.revoked`; 204. Already revoked → 204 without calling the broker. Not
    visible → 404.
  - Audit: `appendAudit(tx, { principalId: memberId, action, subjectType: "connection", subjectId: connection_id,
    details })` in the same transaction as the change. Details hold ids, enums and hashes only.
  - No network call inside withTenant: every broker call happens between the short transactions.
  - Tool descriptions are untrusted: only their hash is stored; never logged.
