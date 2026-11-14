# Wave 1: old workstreams mapped to v2 slices

The old plan (PR #42 `docs/TASKS.md`, section 3) started eight workstreams at once, W1-A to W1-H. This page maps each
one to the v2 slices and milestones that now carry its intent, says who owns it and where it stands, and lists the
owner inputs (operator items O1 to O16 in [ROADMAP M0](ROADMAP.md#operator-items)) it waits on. Words follow
[GLOSSARY.md](GLOSSARY.md). Slice fields are in [AGENTS.md](../AGENTS.md#slice-format).

The old task ids (T-A1 and so on) are PR #42's. v2 does not reuse them; the v2 home is a slice id or a doc section.
Status values: **spec ready** (a `slices/<id>/SPEC.md` with `status: ready` exists), **not specced** (a ROADMAP task
row exists, no SPEC yet), **in docs** (settled in an ADR or doc, no code), **dropped** (not carried over, with the
reason in [MIGRATION.md](MIGRATION.md)). Nothing on this page is built yet.

## Mapping

| Old workstream | Old tasks | v2 slices and docs | Owner | Status | Owner inputs it waits on |
|---|---|---|---|---|---|
| **W1-A** Decisions and scope reset | T-A1 ADRs 0016-0025; T-A2 plan pointer and glossary; T-A3 park Stage 2; T-A4 harness status files; T-A5 secret-scan debt | ADRs 0001 to 0038, [OPEN_QUESTIONS.md](OPEN_QUESTIONS.md), [ROADMAP.md](ROADMAP.md), [GLOSSARY.md](GLOSSARY.md); this page and the five slice specs below. T-A3 is not needed (v2 is a new repo; the old one is left as is). T-A4 is replaced by slice status in SPEC front-matter. T-A5 becomes O14 and the history scan in [DEPLOYMENT section 6.5](DEPLOYMENT.md#65-before-the-public-push) | this run | in docs; this branch adds the slice specs (review pending) | O14 (rotate the exposed key, confirm old canaries are fake, before any old test is ported); O16 (publish the repo); answers to the open questions with defaults ([OQ-12](OPEN_QUESTIONS.md#oq-12-relicensing-code-from-the-old-repo) relicensing gates every port) |
| **W1-B** Distribution spine | T-B1 build flavours; T-B2 CI restructure; T-B3 signing release; T-B4 Sparkle; T-B5 Bun entitlements; T-B6 spike S1; T-B7 spike S2; T-B8 bundle checks | [m3-03-mac-signing-sparkle](../slices/m3-03-mac-signing-sparkle/SPEC.md) (T-B1 flavours as `ai.offload.mac` / `.dev`, T-B3, T-B4, T-B8); the CI `mac` job in `.github/workflows/ci.yml` (T-B2, already shaped); spikes S1 and S2 ([ROADMAP spikes](ROADMAP.md#spikes)) on the owner's Mac. T-B5 dropped: no Bun in the bundle ([MIGRATION section 5.1](MIGRATION.md#51-pr-41-releasemac-testable-m0-installable-build)) | this run (spec); a Sonnet worker builds it | spec ready (m3-03) | O1 Apple enrolment; O2 bundle id; O3 Developer ID and notarization secrets; O4 `workflow` scope; O11 Sparkle EdDSA key and appcast host; O12 macOS CI capacity; O13 `downloads.` domain |
| **W1-C** Cloud foundation | T-C1 scaffold, migrations, audit chain; T-C2 accounts; T-C3 devices; T-C4 model gateway; T-C5 no-content-logging checks; T-C6 IaC; T-C7 static hosting; T-C8 deploy workflow; T-C9 connector broker | [m1-01](../slices/m1-01-durable-spike/SPEC.md), [m1-02](../slices/m1-02-contracts-ingest/SPEC.md), [m1-03](../slices/m1-03-tenancy-rls/SPEC.md), [m1-04](../slices/m1-04-login-devices/SPEC.md) (T-C1 to T-C3); [m2-12-audit-anchors](../slices/m2-12-audit-anchors/SPEC.md) (anchors and verify); [m2-03-credential-broker](../slices/m2-03-credential-broker/SPEC.md) (T-C9); T-C4 splits into the model router [m5-03-model-router](../slices/m5-03-model-router/SPEC.md) and the model egress proxy m2-08; T-C5 is the M2 `CANARY` and `EGRESS` tests; T-C6 to T-C8 are [DEPLOYMENT section 7](DEPLOYMENT.md#7-cloud-deploy-for-the-tenant-of-one) | this run | spec ready (m1-01 to m1-04 from M0; m2-03, m2-12, m5-03 this run); m2-08 and the deploy pipeline not specced | O5 Google Internal OAuth client (login); O7 cloud account, region and KMS key (also the `aws-kms` live test); O8 Anthropic organisation with a spend limit; O13 `api.` domain and TLS; O14 |
| **W1-D** Capture v2 | T-D1 process model; T-D2 Accessibility text; T-D3 OCR fallback; T-D4 session and permission events; T-D5 exclusions v2; T-D6 retention and disk budget; T-D7 observer secret commands; T-D8 resource budget harness | [m3-01-ingest-batches](../slices/m3-01-ingest-batches/SPEC.md) (server side), [m3-02-mac-capture-upload](../slices/m3-02-mac-capture-upload/SPEC.md) (T-D1 to T-D6 and the Keychain part of T-D7); m3-04 (onboarding permissions, now line, Never watch) and m3-05 (recordings import) carry PR #44's port ([MIGRATION section 5.5](MIGRATION.md#55-pr-44-featcapture-from-clicky-s34-recordings-ingest)); T-D8 is the `PERF:` test (m3-04, manual on the owner's Mac) | PR #44 | spec ready (m3-01, m3-02); m3-04 and m3-05 not specced | O1, O2, O3 (a signed bundle so TCC grants persist; spike S1); O4 and O12 (CI `mac` job); O14; O15 privacy policy and terms (linked from "What leaves your Mac") |
| **W1-E** Store and egress | T-E1 redaction corpus; T-E2 egress guard core; T-E3 detectors to TypeScript; T-E4 identity placeholders; T-E5 egress ledger; T-E6 SQLCipher spike; T-E7 memory DB; T-E8 retention tiers | m3-02 (encrypted store, egress guard, local egress ledger: T-E2, T-E5 on the Mac); m3-01 (`packages/masking` transport check: T-E3 server half); [m5-03-model-router](../slices/m5-03-model-router/SPEC.md) (person placeholders, held-out names corpus: T-E1 names part, T-E4 server half); M2 `EGRESS` lint (server). T-E6 and T-E7 dropped: the cloud store is Postgres ([ADR 0019](adr/0019-user-model-storage.md)); T-E8 is m3-01's retention purge | this run | spec ready (m3-01, m3-02 from M0; m5-03 this run); M2 `EGRESS`/`CANARY` tests not yet in a SPEC | O14; O15; O10 Anthropic zero data retention before any second user |
| **W1-F** Agent runtime and models | T-F1 spike S4 owned loop; T-F2 agent loop; T-F3 gate adapter; T-F4 router v2; T-F5 remove product Agent SDK | [m5-03-model-router](../slices/m5-03-model-router/SPEC.md) (T-F4, the allowlist and escalation); the owned Messages-API loop for runtime `model` steps and the gate in m2-10 (T-F1 to T-F3); Agent SDK only inside build sandboxes, m2-07 (T-F5), as [ADR 0021](adr/0021-model-router-and-builders.md) decides | this run | spec ready (m5-03); m2-07 and m2-10 not specced | O8; O6 E2B account (builders, M2 exit); O10 before any second user; model prices for `services/brain/config/models.json` (committed as `null` until set) |
| **W1-G** Connector hub | T-G1 spike S5; T-G2 MCP client; T-G3 OAuth client; T-G4 catalog; T-G5 resolution; T-G6 tool pinning; T-G7 device-side broker client; T-G8 launch allowlist | [m2-02-connections-catalog](../slices/m2-02-connections-catalog/SPEC.md) (T-G4 catalog as data, T-G6 pins, T-G8 capabilities and Composio meta-tool refusal, T-G2 tool listing); [m2-03-credential-broker](../slices/m2-03-credential-broker/SPEC.md) (T-G3 code exchange and refresh, in the broker); spike S5 (T-G1) flips catalog entries to verified; T-G5 run-time resolution is replaced by design-time pins ([ADR 0033](adr/0033-pinned-connector-resolution-and-launch-catalog.md)); T-G7 dropped (the Mac holds no connector keys) | this run | spec ready (m2-02, m2-03) | O5 (Google apps); O9 Composio project if Slack, QuickBooks or Xero is used; the owner's answer to [OQ-22](OPEN_QUESTIONS.md#oq-22-your-first-hand-fed-task-and-top-admin-drains) (first task) and [OQ-24](OPEN_QUESTIONS.md#oq-24-who-owns-the-oauth-clients) (who owns the OAuth clients); a Stripe restricted read key for S5 |
| **W1-H** Shell and onboarding UI | T-H1 onboarding model; T-H2 screens; T-H3 permission helper; T-H4 menu bar item; T-H5 Home skeleton; T-H6 copy pass | m3-04 (onboarding permissions, local now line, Never watch: T-H1 to T-H4 for the M3 screens), m5-05 (Today and Weekly review screens on the Mac: T-H5), m2-11 (minimal web page), the copy lint in `scripts/check-copy.ts` (T-H6). Source spec: [ONBOARDING.md](ONBOARDING.md) | UI & Builds | not specced (ONBOARDING.md is the source) | O1, O2, O3 (signed build for permission flows); O12; O15 (screen 5 links) |

## Slices written in this run

| Slice | Milestone and group | Parallel with | Paths it alone writes while it runs |
|---|---|---|---|
| [m2-02-connections-catalog](../slices/m2-02-connections-catalog/SPEC.md) | M2, M2-A | m2-03 (m2-01 when specced) | `packages/connectors-sdk/**`, `services/api/src/connections/**`, `services/api/src/app.ts`, the contracts generator and `packages/contracts/schemas/**`, migration `0200`, `packages/testkit/src/connectors/**`, `docs/API.md` |
| [m2-03-credential-broker](../slices/m2-03-credential-broker/SPEC.md) | M2, M2-A | m2-02 | `services/broker/**`, `packages/contracts/src/broker/**`, migration `0201`, `packages/testkit/src/broker/**`, `.env.example`, `docs/DEPLOYMENT.md`, `docs/DATA_MODEL.md`, `docs/SECURITY_PRIVACY.md` |
| [m2-12-audit-anchors](../slices/m2-12-audit-anchors/SPEC.md) | M2, M2-A, not parallel-safe | none (runs alone in M2-A; it writes registration files m2-02 owns) | `packages/db/src/audit/**`, `services/api/src/audit/**`, `packages/contracts/src/audit/**`, `packages/testkit/src/audit/**` |
| [m3-03-mac-signing-sparkle](../slices/m3-03-mac-signing-sparkle/SPEC.md) | M3, M3-C | m3-04 to m3-06 when specced, if they stay out of its paths | `.github/workflows/**`, `apps/mac/Package.swift`, `apps/mac/Packaging/**`, `OffloadMac/Updates/**`, `OffloadMac/SelfCheck/**`, the app entry file, `NOTICE` |
| [m5-03-model-router](../slices/m5-03-model-router/SPEC.md) | M5, M5-A | m5-01, m5-02 (they stay out of `services/brain/src/models/**`) | `services/brain/src/models/**`, `services/brain/config/**`, `packages/masking/src/names/**`, `packages/testkit/src/models/**`, `packages/testkit/fixtures/masking/**` |

Package barrels (`src/index.ts` of `contracts`, `testkit`, `masking`, `brain`) are not edited by the parallel M2-A and
M5-A slices; new modules are imported by subpath. Root `package.json` and `bun.lock` follow the AGENTS.md rule (the
second slice to land rebases). Across groups that run at the same time (M2-A with M3-A), the API composition root is
the one shared line: m3-01's SPEC already says M2 tasks rebase before landing.

## Owner inputs by operator item

| Item | Blocks |
|---|---|
| O1 Apple enrolment | W1-B (m3-03 first signed release), W1-D (signed bundle, S1), W1-H |
| O2 bundle id | W1-B, W1-D, W1-H |
| O3 Developer ID and notarization secrets | W1-B, W1-D, W1-H |
| O4 `workflow` scope | W1-B, W1-D (CI `mac` job on GitHub) |
| O5 Google Internal OAuth client | W1-C (login), W1-G (Google apps, S5) |
| O6 E2B account | W1-F (builders, M2 exit) |
| O7 cloud account, region, KMS key | W1-C (deploy, `aws-kms` live test) |
| O8 Anthropic organisation and spend limit | W1-C, W1-F |
| O9 Composio project | W1-G (only if a Composio app is used) |
| O10 Anthropic zero data retention | W1-E, W1-F (before any second user) |
| O11 Sparkle EdDSA key and appcast host | W1-B |
| O12 macOS CI capacity | W1-B, W1-D, W1-H |
| O13 product domain and TLS | W1-B (appcast), W1-C (API host) |
| O14 key rotation and fake canaries | W1-A, W1-C, W1-D, W1-E (before any old test is ported) |
| O15 privacy policy and terms | W1-D, W1-E, W1-H |
| O16 publish the repository | W1-A (when the owner chooses) |
