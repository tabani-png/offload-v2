# Offload

Do it twice. Offload takes the third.

Offload notices the back-office work you repeat, builds a fix for it after you say OK, installs it after you say OK
again, and tells you how many hours it saved. A product of consultance.ai.

**Status: architecture only.** This repo holds the v2 design docs and an empty monorepo skeleton. There is no feature
code yet. The first milestones run Offload for one person (the owner) end to end. See [ROADMAP](docs/ROADMAP.md).

## How it works

1. A thin Mac client watches your work and masks it on your Mac before anything leaves.
2. A cloud brain learns your day, your goals and your history, without keeping your screen.
3. It ranks repeated work against your goals. Every number comes from code and opens to how it was counted.
4. You press **OK, build**. A sandboxed worker builds the fix test-first. It must pass checks it never saw and replay
   your own past instances. A build costs at most $4.00.
5. A second OK installs it. It asks before sending anything until it has earned your trust.
6. It measures the hours saved and shows them next to the estimate every week.

## Docs

| Doc | What |
|---|---|
| [PRODUCT](docs/PRODUCT.md) | Vision, personas, jobs, screens, copy rules, non-goals |
| [ARCHITECTURE](docs/ARCHITECTURE.md) | Every component with a diagram, and the end-to-end sequence |
| [ADRs](docs/adr/README.md) | 24 decisions, one per file |
| [DATA_MODEL](docs/DATA_MODEL.md) | Tables, keys, tenancy, bi-temporal fields, retention |
| [API](docs/API.md) | REST, device ingest, MCP server, webhooks, events |
| [SECURITY_PRIVACY](docs/SECURITY_PRIVACY.md) | Threat model, data classes, what leaves the Mac, sandboxes |
| [OPEN_CORE](docs/OPEN_CORE.md) | License, Free / Pro / Enterprise split, gating |
| [ROADMAP](docs/ROADMAP.md) | Milestones M0 to M9 with acceptance tests |
| [MIGRATION](docs/MIGRATION.md) | What is harvested from the old repo and its branches |
| [OPEN_QUESTIONS](docs/OPEN_QUESTIONS.md) | Owner decisions, each with a recommended default |
| [GLOSSARY](docs/GLOSSARY.md) | The one vocabulary |
| [AGENTS](AGENTS.md) · [CLAUDE](CLAUDE.md) | How agents work here |

## Repo map

```
apps/mac            Swift 6 SwiftPM Mac client (empty targets; builds on macOS only)
apps/web            React 19 + Vite web app (Pro, Enterprise)
services/api        HTTP edge: REST, device ingest, MCP server, webhooks, auth
services/brain      understanding, user model, opportunity finder, fix designer, model router
services/builder    build orchestrator, sandboxes, verifier, receipts
services/runtime    routines, gate, item journal, connectors, hs-1 measurement
packages/contracts  zod + JSON Schema 2020-12 contracts, JCS, hashes
packages/db         migrations, RLS, withTenant, durable runtime port, audit chain
packages/hours-saved  hs-1 (to be ported unchanged)
packages/policy     Cedar policy engine and built-in policies
packages/connectors-sdk  connector port: MCP, Composio, OpenAPI, browser
packages/masking    server-side masking and leak scanner
packages/license    offline license-key verification
packages/testkit    fixtures and fakes
ee/                 Enterprise code (identity, governance, audit-export, server-ee); see ee/LICENSE
infra/              docker-compose (Postgres 17 + pgvector), Helm placeholder
slices/             slice specs and verify scripts (_template + M1)
scripts/            harness: verify-all, license boundary, slices, doc links, copy, secrets
docs/               everything above
```

Each package exports only a TODO marker type and has one passing smoke test.

## Run the harness

Needs Bun 1.3 or later (pinned 1.4.4).

```
bun install
bash scripts/verify-all.sh
```

That runs: install, `tsc --noEmit` over all workspaces, `bun test`, the license-boundary check (core never imports
`ee/`), the slice lint, the doc link check, the product copy lint, and the secrets hygiene check. The Swift package
builds only on macOS (`cd apps/mac && swift build && swift test`, CI job `mac`).

## License

Pending the owner's decision ([OQ-11](docs/OPEN_QUESTIONS.md#oq-11-license-for-the-core-and-for-ee)). Recommended
default: Apache-2.0 for the core and a commercial license for `ee/`. Until then no license is granted. See
[LICENSE](LICENSE), [ee/LICENSE](ee/LICENSE) and [NOTICE](NOTICE).
