# Architecture decision records

One decision per file. Numbered from 0001. Format: Status, Date, Context, Decision, Consequences, Alternatives
considered, Sources (and Revisions when revised).

Editing rule: until the first feature slice is `done`, an ADR may be revised in place. Its status line then says
`accepted, revised 2026-11-14` (or the date of the revision) and a `## Revisions` section lists what changed and why,
with the review or PR that caused it. After the first feature slice is `done`, ADRs are append-only: to change a
decision, add a new ADR that supersedes the old one and set the old one's status to `superseded by NNNN`. New
decisions always get a new number at the end.

Old-repo ADRs are cited as "old ADR 0005" (stage 1, `plan/adr/`) or "old ADR 0103" (stage 2, `plan/stage-2/adr/`).
They are inputs, not part of this repo. [MIGRATION.md](../MIGRATION.md) maps each one.

| # | Decision | Status |
|---|---|---|
| [0001](0001-record-decisions-and-v2-scope.md) | Fresh v2 repo, harvest the old one, record decisions here | accepted, revised 2026-11-14 |
| [0002](0002-stack-bun-typescript-hono-postgres.md) | TypeScript strict on Bun, Hono, Postgres 17 as the one required datastore | accepted, revised 2026-11-14 |
| [0003](0003-numbers-come-from-code.md) | Numbers come from code, never a model | accepted, revised 2026-11-14 |
| [0004](0004-every-external-action-is-gated.md) | Every external action is gated | accepted, revised 2026-11-14 |
| [0005](0005-masked-text-only-reaches-models.md) | Masked text only reaches models | accepted, revised 2026-11-14 |
| [0006](0006-metadata-first-capture.md) | Metadata-first, Accessibility-first capture, fail closed | accepted, revised 2026-11-14 |
| [0007](0007-cloud-brain-thin-mac-client.md) | Cloud brain, thin Mac client | accepted, revised 2026-11-14 |
| [0008](0008-contracts-first.md) | Contracts first, one package | accepted, revised 2026-11-14 |
| [0009](0009-durable-execution-on-postgres.md) | Durable execution on Postgres (DBOS Transact behind a port) | accepted, revised 2026-11-14; spike result pending (m1-01) |
| [0010](0010-mcp-first-connectors.md) | MCP-first connectors, then Composio, OpenAPI, browser | accepted, revised 2026-11-14 |
| [0011](0011-sandboxed-build-workers.md) | Sandboxed build workers | accepted, revised 2026-11-14 |
| [0012](0012-builder-policy-one-worker-held-out-fan-out.md) | Builder policy: 1 worker + held-out check, fan out on failure, $4 cap | accepted, revised 2026-11-14 |
| [0013](0013-tenancy-and-rls.md) | Tenancy: tenant, workspace, member; Postgres RLS | accepted, revised 2026-11-14 |
| [0014](0014-identity.md) | Identity: one OIDC provider in core, SAML/SCIM in EE, device keys | accepted, revised 2026-11-14 |
| [0015](0015-open-core-layout-and-license-gating.md) | Open-core layout (`ee/`) and runtime license gating | accepted, revised 2026-11-14; plan split decided (OQ-13), license text pending OQ-11, prices open |
| [0016](0016-no-dry-run.md) | No dry run: verify inside the build, ask before commit after deploy | accepted, revised 2026-11-14 |
| [0017](0017-policy-engine-cedar.md) | Policy engine: TypeScript rules first, Cedar for custom policies | accepted, revised 2026-11-14 |
| [0018](0018-audit-log-hash-chain.md) | Audit log: append-only, hash-chained, anchored | accepted, revised 2026-11-14 |
| [0019](0019-user-model-storage.md) | User model in Postgres (bi-temporal tables, pgvector); graph port with optional graphiti | accepted, revised 2026-11-14 |
| [0020](0020-device-ingest-protocol.md) | Device ingest protocol: signed batches, closed upload kinds, idempotent | accepted, revised 2026-11-14 |
| [0021](0021-model-router-and-builders.md) | Model router and builder models | accepted, revised 2026-11-14 |
| [0022](0022-hours-saved-hs-1.md) | Measured hours saved: hs-1 and fix outcomes | accepted, revised 2026-11-14 |
| [0023](0023-service-layout.md) | Modular monolith with four modules; split is a deploy change | accepted, revised 2026-11-14 |
| [0024](0024-client-stacks.md) | Client stacks: Swift 6 SwiftPM Mac client, React 19 + Vite web | accepted, revised 2026-11-14 |
| [0025](0025-execution-placement-and-mac-actuator.md) | Execution placement and the Mac actuator | accepted, revised 2026-11-14 |
| [0026](0026-routine-artifact-contract.md) | Routine artifact contract | accepted |
| [0027](0027-fixture-capture-and-connector-content.md) | Fixture capture and connector content (C6) | accepted |
| [0028](0028-stable-keyed-pseudonyms.md) | Stable keyed pseudonyms and device-side reveal | accepted |
| [0029](0029-build-verdicts.md) | Build verdicts: fresh-sandbox pass, one repair turn, held-out per build | accepted, revised 2026-11-14 |
| [0030](0030-build-budget-at-egress-proxy.md) | Build budget enforced at the model egress proxy | accepted, revised 2026-11-14 |
| [0031](0031-build-infrastructure-failures.md) | Build infrastructure failures: `infra_failed` and the sandbox reaper | accepted |
| [0032](0032-deploy-approval-binds-definition.md) | Deploy approval binds a readable definition | accepted |
| [0033](0033-pinned-connector-resolution-and-launch-catalog.md) | Connector resolution pinned at design time; launch catalog | accepted |
| [0034](0034-credential-broker-and-key-providers.md) | Credential broker and key providers | accepted, revised 2026-11-14 |
| [0035](0035-mac-egress-guard-and-ledger.md) | Mac egress guard and local egress ledger | accepted |
| [0036](0036-opportunity-sources-and-instant-read.md) | Opportunity sources and the instant read | accepted |
| [0037](0037-hosting-cloud-and-self-host-parity.md) | Hosting: Offload Cloud and self-host at parity | accepted (owner decision OQ-29) |
