# Architecture decision records

One decision per file. Numbered from 0001. ADRs are append-only: to change a decision, add a new ADR that supersedes
the old one and set the old one's status to `superseded by NNNN`. Format: Status, Date, Context, Decision,
Consequences, Alternatives considered, Sources.

Old-repo ADRs are cited as "old ADR 0005" (stage 1, `plan/adr/`) or "old ADR 0103" (stage 2, `plan/stage-2/adr/`).
They are inputs, not part of this repo. [MIGRATION.md](../MIGRATION.md) maps each one.

| # | Decision | Status |
|---|---|---|
| [0001](0001-record-decisions-and-v2-scope.md) | Fresh v2 repo, harvest the old one, record decisions here | accepted |
| [0002](0002-stack-bun-typescript-hono-postgres.md) | TypeScript strict on Bun, Hono, Postgres 17 as the one required datastore | accepted |
| [0003](0003-numbers-come-from-code.md) | Numbers come from code, never a model | accepted |
| [0004](0004-every-external-action-is-gated.md) | Every external action is gated | accepted |
| [0005](0005-masked-text-only-reaches-models.md) | Masked text only reaches models | accepted |
| [0006](0006-metadata-first-capture.md) | Metadata-first capture, fail closed | accepted |
| [0007](0007-cloud-brain-thin-mac-client.md) | Cloud brain, thin Mac client | accepted |
| [0008](0008-contracts-first.md) | Contracts first, one package | accepted |
| [0009](0009-durable-execution-on-postgres.md) | Durable execution on Postgres (DBOS Transact behind a port) | accepted, spike in M1 |
| [0010](0010-mcp-first-connectors.md) | MCP-first connectors, then Composio, OpenAPI, browser | accepted |
| [0011](0011-sandboxed-build-workers.md) | Sandboxed build workers: E2B in cloud, container-use or Docker for self-host | accepted |
| [0012](0012-builder-policy-one-worker-held-out-fan-out.md) | Builder policy: 1 worker + held-out check, fan out on failure, $4 cap | accepted |
| [0013](0013-tenancy-and-rls.md) | Tenancy: tenant, workspace, member; Postgres RLS | accepted |
| [0014](0014-identity.md) | Identity: OIDC in core, SAML/SCIM in EE, device keys | accepted |
| [0015](0015-open-core-layout-and-license-gating.md) | Open-core layout (`ee/`) and runtime license gating | accepted, license text pending OQ-11 |
| [0016](0016-no-dry-run.md) | No dry run: verify inside the build, ask before commit after deploy | accepted |
| [0017](0017-policy-engine-cedar.md) | Policy engine: Cedar | accepted |
| [0018](0018-audit-log-hash-chain.md) | Audit log: append-only, hash-chained, anchored | accepted |
| [0019](0019-user-model-storage.md) | User model in Postgres (bi-temporal tables, pgvector); graph port with optional graphiti | accepted |
| [0020](0020-device-ingest-protocol.md) | Device ingest protocol: signed batches, closed upload kinds, idempotent | accepted |
| [0021](0021-model-router-and-builders.md) | Model router and builder models | accepted |
| [0022](0022-hours-saved-hs-1.md) | Measured hours saved: hs-1 | accepted |
| [0023](0023-service-layout.md) | Four services, ingest inside the API service | accepted |
| [0024](0024-client-stacks.md) | Client stacks: Swift 6 SwiftPM Mac client, React 19 + Vite web | accepted |
