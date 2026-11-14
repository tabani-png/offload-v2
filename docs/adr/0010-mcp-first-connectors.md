# 0010. MCP-first connectors, then Composio, OpenAPI, browser

Status: accepted, revised 2026-11-14 · Date: 2026-11-14 · Carries over old ADR 0004, 0007 (connector chain)

## Context
Offload joins tools already on the market instead of rebuilding them. The old chain was MCP → Composio → direct API →
computer use, with a fixed capability vocabulary. From a server, Offload is a confidential OAuth client, which makes
"MCP first" unavailable for several of the tools that matter on day one (review-c P1(3)).

## Decision
- `packages/connectors-sdk` defines the **connector port**: `listCapabilities()`, `read(capability, args)`,
  `draft(capability, args)`, `commit(capability, args, approvalContext)`. Every call names a **capability** from a fixed
  vocabulary and a **step class** (`read`, `draft`, `commit`). Calls go through the credential broker
  ([ADR 0034](0034-credential-broker-and-key-providers.md)).
- **Preference order when the fix designer picks an adapter** for a capability and tenant:
  1. **MCP server** (official or vetted remote MCP servers). Offload is an MCP client.
  2. **Composio toolkit** (hosted platform; SDK is MIT, the platform is a proprietary service under its terms).
  3. **Direct API** from an OpenAPI description, through a generated, allowlisted client.
  4. **Browser automation** last: on the user's Mac in his own logged-in browser, attended
     ([ADR 0025](0025-execution-placement-and-mac-actuator.md)); in the cloud only for service accounts without MFA,
     opt-in. **Commits by browser always ask, even after graduation.** There is no Enterprise exception.
- **Resolution is pinned at design time, never at run time** ([ADR 0033](0033-pinned-connector-resolution-and-launch-catalog.md)):
  the brief names `connection_id`, adapter, tool name and tool pin hash per step. A changed pin pauses the routine.
- Which method each launch app uses is the **launch catalog** in [ADR 0033](0033-pinned-connector-resolution-and-launch-catalog.md),
  including the Composio constraints (opaque `user_id`, explicit allowlists, no meta tools, REST only, retention
  disclosure).
- **Offload also exposes its own MCP server** (`/mcp`, from M8) so other agents can read Offload state and propose
  work. Its tools are read and propose only; nothing commits through it ([API.md](../API.md#5-offload-mcp-server)).
- Capability vocabulary starts with the harvested set: `mail.send`, `mail.search`, `mail.read`, `mail.labels`,
  `sheet.append`, `calendar.free_slots`, `calendar.events`, `crm.note`, `crm.task`, `accounting.bill`, `ticket.reply`,
  `table.create_record`, `chat.post`, `ats.move_stage`, `outreach.add_lead`, `outreach.resume_lead`, `file.read`,
  `screen.read`, `ui.commit`, `web.research`; device capabilities, run only by the Mac actuator as commit-class device
  steps from M6 ([ADR 0025](0025-execution-placement-and-mac-actuator.md)): `shortcut.run`, `appleevent.template`,
  `ax.action`, `browser.step`. New capabilities are added in `packages/contracts` with a schema for
  their arguments.
- Argument allowlists: every commit capability has an argument schema; arguments outside it are refused. Some tool
  slugs are denied on purpose (for example bulk campaign activation, bill payment).
- **Credential vault**: credentials are stored per tenant with envelope encryption under a key provider; only the
  broker decrypts them. Workers and models never see them. Where the platform supports it, Offload holds only a
  reference (Composio connected account id, MCP OAuth grant).

## Consequences
- Each connector adapter has a fake for tests (`packages/testkit`, targeting the routine SDK). Live tests run only with
  credentials present and are never faked.
- MCP tool descriptions and results are untrusted input ([SECURITY_PRIVACY.md](../SECURITY_PRIVACY.md#7-prompt-injection-defenses)).
- "MCP first" is a preference; for Google apps on day one the catalog picks his own internal OAuth client, then
  Composio.

## Alternatives considered
- n8n as the integration layer: Sustainable Use License forbids offering it as a service to others. Rejected (also old ADR 0004).
- Composio first: fewer moving parts but ties every tenant to a proprietary service.
- Resolve the adapter per step at run time (the previous version). Rejected: an artifact verified against one adapter's
  shapes would run against another (review-c P1(3)).

## Sources
Old ADR 0004, 0007, 0015; old `brain/src/connectors/*`, `workflows/allowlist.ts`; PR #42 A§10.3-10.5.

## Revisions
- 2026-11-14: resolution pinned at design time and launch catalog moved to ADR 0033 (review-c P1(3)); browser
  automation runs on the device and browser commits always ask, Enterprise exception removed (review-c P0-1, review-a
  #56); credentials only through the broker; Offload MCP server lands in M8.
- 2026-11-14 (final pass): device capabilities `shortcut.run`, `appleevent.template`, `ax.action`, `browser.step` added to the vocabulary (final-pass audit).
