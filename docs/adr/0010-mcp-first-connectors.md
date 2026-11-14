# 0010. MCP-first connectors, then Composio, OpenAPI, browser

Status: accepted · Date: 2026-11-14 · Carries over old ADR 0004, 0007 (connector chain)

## Context
Offload joins tools already on the market instead of rebuilding them. The old chain was MCP → Composio → direct API →
computer use, with a fixed capability vocabulary.

## Decision
- `packages/connectors-sdk` defines the **connector port**: `listCapabilities()`, `read(capability, args)`,
  `draft(capability, args)`, `commit(capability, args, approvalContext)`. Every call names a **capability** from a fixed
  vocabulary and a **step class** (`read`, `draft`, `commit`).
- Resolution order per capability and tenant:
  1. **MCP server** (official or vetted remote MCP servers). Offload is an MCP client.
  2. **Composio toolkit** (hosted platform; SDK is MIT, the platform is a proprietary service under its terms).
  3. **Direct API** from an OpenAPI description, through a generated, allowlisted client.
  4. **Browser automation** last: Playwright in a sandbox, or computer use (`computer_toolset_20260801`) for apps with
     no API. Commits by browser always ask, even after graduation, unless an Enterprise policy says otherwise.
- **Offload also exposes its own MCP server** (`/mcp` on the API service) so other agents can read Offload state and
  propose work. Its tools are read and propose only; nothing commits through it ([API.md](../API.md#4-offload-mcp-server)).
- Capability vocabulary starts with the harvested set: `mail.send`, `mail.search`, `mail.read`, `mail.labels`,
  `sheet.append`, `calendar.free_slots`, `calendar.events`, `crm.note`, `crm.task`, `accounting.bill`, `ticket.reply`,
  `table.create_record`, `chat.post`, `ats.move_stage`, `outreach.add_lead`, `outreach.resume_lead`, `file.read`,
  `screen.read`, `ui.commit`, `web.research`. New capabilities are added in `packages/contracts` with a schema for
  their arguments.
- Argument allowlists: every commit capability has an argument schema; arguments outside it are refused. Some tool
  slugs are denied on purpose (for example bulk campaign activation, bill payment).
- **Credential vault**: credentials are stored per tenant with envelope encryption (a per-tenant data key wrapped by
  KMS). Workers and models never see them. The runtime injects them at call time. Where the platform supports it,
  Offload holds only a reference (Composio connected account id, MCP OAuth grant).

## Consequences
- Each connector adapter has a fake for tests. Live tests run only with credentials present and are never faked.
- MCP tool descriptions and results are untrusted input ([SECURITY_PRIVACY.md](../SECURITY_PRIVACY.md#7-prompt-injection-defenses)).

## Alternatives considered
- n8n as the integration layer: Sustainable Use License forbids offering it as a service to others. Rejected (also old ADR 0004).
- Composio first: fewer moving parts but ties every tenant to a proprietary service.

## Sources
Old ADR 0004, 0007, 0015; old `brain/src/connectors/*`, `workflows/allowlist.ts`.
