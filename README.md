# Offload

Do it twice. Offload takes the third.

Offload notices the back-office work you repeat, builds a fix for it after you say OK, installs it after you say OK
again, and tells you how many hours it saved. A product of consultance.ai.

**Status: architecture and docs only, public.** This repo holds the v2 design docs and an empty monorepo skeleton,
and it is meant to be read in the open ([OQ-27](docs/OPEN_QUESTIONS.md#oq-27-publish-the-repository-publicly)). There
is no feature code yet. The core is MIT; `ee/` is under the Offload Enterprise License ([License](#license)).

The first milestones run Offload for one person (the owner) end to end: M1 builds the foundations, M2 runs a hand-fed
loop first (one task he names, built, deployed and run on his real accounts), and M3 brings capture to the cloud in
parallel. Slice specs with named red tests are ready for M1 (`m1-01` to `m1-05`) and M3 (`m3-01`, `m3-02`). See
[ROADMAP](docs/ROADMAP.md).

Decided by the owner: one person free, teams pay; Offload Cloud and self-host with the same features; masked screen
text may go to the cloud, pixels stay on the Mac. Prices and the other owner decisions are open with recommended
defaults in [OPEN_QUESTIONS](docs/OPEN_QUESTIONS.md).

## How it works

1. A thin Mac client watches your work and masks it on your Mac before anything leaves. Masked text from your screen
   is uploaded; people and documents appear only as pseudonyms.
2. A cloud brain learns your day, your goals and your history, without keeping your screen.
3. It ranks repeated work against your goals. Every number comes from code and opens to how it was counted.
4. You press **OK, build**. A sandboxed worker builds the fix test-first. It must pass checks it never saw and replay
   your own past instances. A build costs at most $4.00.
5. A second OK installs it, after you read what it will do and with which accounts. It asks before sending anything
   until it has earned your trust.
6. It measures the hours saved and shows them next to the estimate every week.

One person uses it free. Teams pay. Run it on Offload Cloud or on your own servers, with the same features.

## Read order

1. This file, then [GLOSSARY](docs/GLOSSARY.md) (the only vocabulary).
2. [ARCHITECTURE](docs/ARCHITECTURE.md), then the [ADRs](docs/adr/README.md) it links.
3. [DATA_MODEL](docs/DATA_MODEL.md) and [API](docs/API.md), then [SECURITY_PRIVACY](docs/SECURITY_PRIVACY.md).
4. [ROADMAP](docs/ROADMAP.md) and the slice you work on (`slices/<id>/SPEC.md`).
5. Agents: [AGENTS](AGENTS.md) and [CLAUDE](CLAUDE.md) before the first change. All building here is done with Claude
   Code (Opus or Fable 5.2 for design and review, Sonnet for implementation).

## Docs

| Doc | What |
|---|---|
| [PRODUCT](docs/PRODUCT.md) | Vision, personas, jobs, screens, copy rules, non-goals |
| [ARCHITECTURE](docs/ARCHITECTURE.md) | Every component with a diagram, and the end-to-end sequence |
| [ADRs](docs/adr/README.md) | 37 decisions, one per file |
| [DATA_MODEL](docs/DATA_MODEL.md) | Tables, keys, tenancy, bi-temporal fields, retention |
| [API](docs/API.md) | REST, device ingest, MCP server, webhooks, events |
| [SECURITY_PRIVACY](docs/SECURITY_PRIVACY.md) | Threat model, data classes, what leaves the Mac, sandboxes |
| [OPEN_CORE](docs/OPEN_CORE.md) | License, Free / Pro / Enterprise split, gating |
| [ROADMAP](docs/ROADMAP.md) | Milestones M0 to M9 with acceptance tests |
| [ONBOARDING](docs/ONBOARDING.md) | First-run flow, permissions, skip paths, re-consent |
| [DEPLOYMENT](docs/DEPLOYMENT.md) | Signing, notarization, Sparkle, Offload Cloud and self-host side by side |
| [MIGRATION](docs/MIGRATION.md) | What is harvested from the old repo and its branches |
| [SOURCES](docs/SOURCES.md) | Named sources the docs cite: public links and internal notes |
| [OPEN_QUESTIONS](docs/OPEN_QUESTIONS.md) | Owner decisions, each with a recommended default |
| [GLOSSARY](docs/GLOSSARY.md) | The one vocabulary |
| [AGENTS](AGENTS.md) · [CLAUDE](CLAUDE.md) | How agents work here |

## Repo map

```
apps/mac            Swift 6 SwiftPM Mac client (empty targets; builds on macOS only)
apps/web            React 19 + Vite web app (all plans; hosted on Pro and Enterprise)
services/api        module: HTTP edge, REST, device ingest, device commands, webhooks, auth
services/brain      module: understanding, user model, opportunity finder, fix designer, model router
services/builder    module: build orchestrator, sandboxes, model egress proxy, verifier, receipts
services/runtime    module: routines, gate, item journal, device command queue, hs-1 measurement
services/broker     separate process: credential broker, the only holder of decrypt rights
packages/contracts  zod + JSON Schema 2020-12 contracts, JCS, hashes
packages/db         migrations, RLS, withTenant, durable runtime port, audit chain
packages/routine-sdk  routine artifact contract: routine.json schema, pure transforms
packages/hours-saved  hs-1 (to be ported unchanged)
packages/policy     policy engine port with built-in TypeScript rules
packages/connectors-sdk  connector port: MCP, Composio, OpenAPI, browser
packages/masking    server-side masking and transport leak scan
packages/license    offline license-key verification
packages/testkit    fixtures, fake connector, fakes
ee/                 Enterprise code (identity, governance, audit-export, server-ee); see ee/LICENSE
infra/              self-host skeletons: docker-compose (one host), Helm chart (Kubernetes)
slices/             slice specs and verify scripts (_template, M1, M3, Wave 1: docs/WAVE1.md)
scripts/            harness: verify-all, license boundary, slices, doc links, copy, secrets, workflows
docs/               everything above
```

The four `services/*` modules run as one process (`offload serve`, a modular monolith) until there is a second
tenant; splitting them is a deploy change. The broker always runs as its own process.

Each package exports only a TODO marker type and has one passing smoke test.

## Run the harness

Needs Bun 1.3 or later (pinned 1.4.4).

```
bun install
bash scripts/verify-all.sh
```

That runs: install, `tsc --noEmit` over all workspaces, `bun test`, the license-boundary check (core never imports
`ee/`), the slice lint (front-matter, `verify.sh` config, and `verify.sh` of every `done` slice), the doc link check,
the product copy lint (no dry-run terms; no banned words or em dashes in user-visible strings), the secrets hygiene
check and the CI workflow YAML check. One slice: `bash slices/<id>/verify.sh`. The Swift package
builds only on macOS (`cd apps/mac && swift build && swift test`, CI job `mac`).

## License

Decided 2026-11-14 ([OQ-11](docs/OPEN_QUESTIONS.md#oq-11-license-for-the-core-and-for-ee),
[ADR 0038](docs/adr/0038-license-mit-core-commercial-ee.md)). Everything outside `ee/` is MIT (Expat). Everything under
`ee/` is under the Offload Enterprise License: source-available, free for development and testing, production use
needs a license key and a subscription. The `ee/` text is a draft pending legal review before the first paid customer.
Third-party components keep their own licenses. See [LICENSE](LICENSE), [ee/LICENSE](ee/LICENSE) and
[NOTICE](NOTICE).
