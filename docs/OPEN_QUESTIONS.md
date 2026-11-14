# Open questions for the owner

Decisions only Muhammad can make. Each has options and a **recommended default**. Agents build on the default; the
question stays here, marked, until he answers. Ordered by how much they block, most blocking first. When one is
answered, write the answer under it, update the docs that cite it, and add an ADR if it changes a decision.

Status key: **open** (building on the default), **answered**.

| # | Question | Default | Blocks |
|---|---|---|---|
| [OQ-01](#oq-01-cloud-hosting-provider-and-region) | Cloud host and region | AWS `ca-central-1` | M1 deploy |
| [OQ-02](#oq-02-raw-ttl-for-masked-observations-in-the-cloud) | Raw TTL in the cloud | 30 days | M1 |
| [OQ-03](#oq-03-keep-the-derived-user-model-long-term) | Keep the derived user model long term | yes, with controls | M2 |
| [OQ-04](#oq-04-keyframes-to-the-cloud) | Masked keyframes to the cloud | off | M2 |
| [OQ-05](#oq-05-model-provider-terms-and-monthly-model-budget) | Model provider terms, monthly budget | Anthropic API, $50/month | M2 |
| [OQ-06](#oq-06-identity-provider-for-offload-cloud) | Identity provider for Offload Cloud | WorkOS AuthKit | M1 (cloud login) |
| [OQ-07](#oq-07-design-budget-before-ok-build) | Design budget before OK, build | $0.60 per opportunity | M4 |
| [OQ-08](#oq-08-sandbox-provider-for-cloud-builds) | Sandbox provider for cloud builds | E2B | M4 |
| [OQ-09](#oq-09-graduation-threshold) | Graduation threshold | 5 clean runs + your OK | M5/M7 |
| [OQ-10](#oq-10-build-progress-screen-rows) | Build progress rows: check groups or workers | check groups | M4 UI |
| [OQ-11](#oq-11-license-for-the-core-and-for-ee) | License for core and `ee/` | Apache-2.0 + commercial EE | public release (M8) |
| [OQ-12](#oq-12-relicensing-code-from-the-old-repo) | Relicensing old-repo code | relicense under the v2 license | first port |
| [OQ-13](#oq-13-plan-contents-and-prices) | Plan contents and prices | Free / Pro / Enterprise as in OPEN_CORE | M8 |
| [OQ-14](#oq-14-optional-graphiti-adapter-and-graph-backend-licenses) | graphiti adapter in distribution | not shipped by default | M7 |
| [OQ-15](#oq-15-monitoring-law-features-for-teams) | Per-person team features | Enterprise only, off by default | M8/M9 |
| [OQ-16](#oq-16-mac-distribution-and-signing) | Mac distribution and signing | Developer ID + notarized DMG | M1 exit demo on other Macs, M8 |
| [OQ-17](#oq-17-privacy-policy-terms-and-dpa) | Privacy policy, terms, DPA | lawyer-reviewed before Pro | M8 |
| [OQ-18](#oq-18-which-cortexa) | Which Cortexa did you mean | Cortexa Labs (Paladin) | none |
| [OQ-19](#oq-19-what-is-fable-52-and-should-it-shape-the-architecture) | What is Fable 5.2 | no architecture change until known | none known |
| [OQ-20](#oq-20-brand-logos-in-the-app) | Third-party brand logos in the app | monograms until reviewed | M8 UI |

## OQ-01: Cloud hosting provider and region

Status: open.
- **Question**: Where does Offload Cloud run first?
- **Options**: (a) AWS `ca-central-1` (Montreal): managed Postgres 17 with pgvector, S3, KMS, Canadian residency.
  (b) GCP `northamerica-northeast2` (Toronto). (c) Fly.io / Render / Railway: simpler, weaker KMS and residency story.
  (d) A Hetzner box: cheapest, most ops work.
- **Recommended default**: (a) AWS `ca-central-1`. You are in Toronto; Canadian data residency helps later Canadian
  customers; KMS and RDS cover the envelope-encryption and backup design.
- **Affects**: [ARCHITECTURE section 14](ARCHITECTURE.md#14-deployment), [SECURITY_PRIVACY.md section 10](SECURITY_PRIVACY.md#10-sub-processors).

## OQ-02: Raw TTL for masked observations in the cloud

Status: open.
- **Question**: How long do masked observations (`C1`) stay in the cloud before deletion?
- **Options**: 7 days (the old README promise), 30 days (the old `s32-retention-30d` change), 90 days.
- **Recommended default**: **30 days**. Long enough to rebuild a month of records and fixtures after a bug fix; short
  enough to keep the "raw data expires" promise. The constant is `RAW_TTL_DAYS`; code never hard-codes it.
- **Affects**: [DATA_MODEL.md](DATA_MODEL.md#1-conventions) `R-raw`, onboarding copy, slice m1-04.

## OQ-03: Keep the derived user model long term

Status: open.
- **Question**: May Offload keep derived data (episodes, records, entities, facts, propositions; no raw screen data)
  after raw data expires? The old README promised everything older than 7 days is deleted.
- **Options**: (a) yes, until you forget it, with export/forget/pause controls; (b) cap at 12 months; (c) no.
- **Recommended default**: (a), with onboarding copy that says so plainly and the forget controls in Settings. The
  weekly, monthly and quarterly review depends on it.
- **Affects**: [ADR 0019](adr/0019-user-model-storage.md), `R-model`.

## OQ-04: Keyframes to the cloud

Status: open.
- **Question**: Should masked keyframes ever leave the Mac (for captioning by Haiku)?
- **Options**: (a) never; (b) opt-in per user (`keyframes_to_cloud`), default off; (c) on by default.
- **Recommended default**: (b), default off. Understanding works from metadata and masked text; images are an
  optional quality boost.
- **Affects**: [ADR 0005](adr/0005-masked-text-only-reaches-models.md), [SECURITY_PRIVACY.md section 3](SECURITY_PRIVACY.md#3-what-leaves-the-mac).

## OQ-05: Model provider terms and monthly model budget

Status: open.
- **Question**: Which provider account and data terms for model calls, and what monthly cap for your tenant?
- **Options**: Anthropic API with standard retention; Anthropic with zero data retention (some models unavailable);
  BYOK per tenant; Bedrock/Vertex.
- **Recommended default**: Anthropic API, standard retention, masked text only; **$50/month** cap for your tenant of one
  (builds are capped separately at $4.00 each and count toward it). BYOK available to every tenant.
- **Affects**: [ADR 0021](adr/0021-model-router-and-builders.md), `tenants.monthly_model_budget_usd`.

## OQ-06: Identity provider for Offload Cloud

Status: open.
- **Question**: Which hosted login for Offload Cloud?
- **Options**: WorkOS AuthKit (old ADR 0102; SSO and SCIM later), Clerk, Auth0, self-run (Keycloak, Zitadel).
- **Recommended default**: WorkOS AuthKit, used only as an OIDC issuer from core; SAML/SCIM through WorkOS in EE on
  Cloud. Core stays vendor-free.
- **Affects**: [ADR 0014](adr/0014-identity.md).

## OQ-07: Design budget before OK, build

Status: open.
- **Question**: How much may Offload spend writing the brief, the check set and the held-out check before you press
  OK, build? (This is outside the $4.00 build cap you set.)
- **Options**: $0.30, $0.60, $1.00 per opportunity.
- **Recommended default**: **$0.60** (bench: check writing cost about $0.11 per brief; held-out about $0.10; Opus
  wording on top).
- **Affects**: [ADR 0012](adr/0012-builder-policy-one-worker-held-out-fan-out.md).

## OQ-08: Sandbox provider for cloud builds

Status: open.
- **Question**: Which sandbox runs cloud builds?
- **Options**: E2B (Firecracker microVMs, Apache-2.0 SDK, hosted); self-run Firecracker; Modal; Daytona (archived
  July 2026, avoid); Claude Managed Agents sandboxes.
- **Recommended default**: E2B, behind the `SandboxProvider` port.
- **Affects**: [ADR 0011](adr/0011-sandboxed-build-workers.md), sub-processor list.

## OQ-09: Graduation threshold

Status: open.
- **Question**: When may a routine stop asking before each commit?
- **Options**: never by default; after N clean runs with your one-tap OK; after N clean runs automatically.
- **Recommended default**: after **5 consecutive approved runs with no edits and no failed or unknown items**, Offload
  proposes it and you confirm with one tap. Browser-automation commits keep asking.
- **Affects**: [ADR 0016](adr/0016-no-dry-run.md), [ARCHITECTURE section 11](ARCHITECTURE.md#11-routine-runtime).

## OQ-10: Build progress screen rows

Status: open.
- **Question**: The approved mockup shows 8 named workers, each in its own sandbox. The bench decision is one worker
  by default, more only on failure. What should the rows be?
- **Options**: (a) rows are **check groups** inside one worker, with worker tabs appearing only on fan-out; (b) keep
  8 worker rows (not true to how it runs).
- **Recommended default**: (a). Same look, honest about the mechanics. Copy stays "each in its own sandbox" only when
  fan-out happens.
- **Affects**: [PRODUCT.md section 6](PRODUCT.md#6-ui-direction), Build progress screen (M4).

## OQ-11: License for the core and for EE

Status: open.
- **Question**: Which licenses?
- **Options**: core Apache-2.0, MIT, AGPL-3.0, or fair-code (Sustainable Use); EE commercial (Langfuse style) or BSL.
- **Recommended default**: **Apache-2.0 core** (patent grant) + **commercial Offload Enterprise License for `ee/`**,
  source-visible, production use needs a key.
- **Affects**: `LICENSE`, `ee/LICENSE`, [OPEN_CORE.md](OPEN_CORE.md#1-license).

## OQ-12: Relicensing code from the old repo

Status: open.
- **Question**: The old repo is "all rights reserved" (yours). May its code be relicensed under the v2 license when
  ported?
- **Options**: yes for everything; yes except named parts; no (rewrite clean-room).
- **Recommended default**: yes for everything you wrote. Third-party pieces keep their own licenses in `NOTICE`.
- **Affects**: every port in [MIGRATION.md](MIGRATION.md).

## OQ-13: Plan contents and prices

Status: open.
- **Question**: What exactly is in Pro, and what do Pro and Enterprise cost? (Pricing page v3 labels prices as proposals.)
- **Options**: see [OPEN_CORE.md section 2](OPEN_CORE.md#2-feature-split); alternative: Free and Enterprise only.
- **Recommended default**: the table in OPEN_CORE.md; no prices in product docs until you set them.
- **Affects**: OPEN_CORE.md, web app billing (M8).

## OQ-14: Optional graphiti adapter and graph backend licenses

Status: open.
- **Question**: Ship a graphiti adapter? Its backends are FalkorDB (source-available, SSPL-style terms) or Neo4j
  Community (GPLv3); Kuzu was archived in October 2025.
- **Options**: (a) Postgres only, no adapter; (b) adapter as an optional plug-in the self-hoster installs, not in our
  images; (c) ship FalkorDB in our images.
- **Recommended default**: (b). Default distribution is Postgres only.
- **Affects**: [ADR 0019](adr/0019-user-model-storage.md).

## OQ-15: Monitoring-law features for teams

Status: open.
- **Question**: Do per-person views and working time exist at all for teams, and in which plan?
- **Options**: not at all; Enterprise only with compliance records (old ADR 0108); Pro and Enterprise.
- **Recommended default**: Enterprise only, off by default, owner enablement with DPIA attestation and notice period.
  Workflow-level metrics with a group floor of 5 are available to all team plans.
- **Affects**: [SECURITY_PRIVACY.md section 12](SECURITY_PRIVACY.md#12-compliance-notes-not-legal-advice).

## OQ-16: Mac distribution and signing

Status: open.
- **Question**: How is the Mac client distributed?
- **Options**: ad-hoc signed builds for you only; Developer ID signed + notarized DMG; Mac App Store (sandboxing
  conflicts with Accessibility and screen capture needs).
- **Recommended default**: Developer ID + notarized DMG from CI (needs an Apple Developer account under consultance.ai).
- **Affects**: [ADR 0024](adr/0024-client-stacks.md), M8.

## OQ-17: Privacy policy, terms and DPA

Status: open.
- **Question**: Offload's own privacy policy, terms and DPA with sub-processors.
- **Recommended default**: draft from [SECURITY_PRIVACY.md](SECURITY_PRIVACY.md) and have a lawyer review before any
  user other than you.
- **Affects**: M8 exit.

## OQ-18: Which Cortexa

Status: open.
- **Question**: The research Page assumed Cortexa Labs (Paladin: policy checks on every agent tool call, signed
  receipts). The repo-scout log thought cortexa.network (process intelligence, operations graph). Which did you mean?
- **Recommended default**: Cortexa Labs. We borrowed only patterns either way: rule id on every decision, signed
  receipts, governed flows. No code.
- **Affects**: nothing blocking.

## OQ-19: What is Fable 5.2 and should it shape the architecture?

Status: open.
- **Question**: You mentioned "Fable 5.2" when asking for this work. Nobody knows yet what you meant. We did not guess.
- **One fact that may help**: the Claude model catalog available to the agent that wrote these docs lists a model
  named **Claude Fable 5.2** (`claude-fable-5-2`), priced above Opus. If that is what you meant, the router can add it
  as a configurable tier for the hardest design or verify routes; that is a config change, not an architecture change.
  If you meant something else, tell us what.
- **Recommended default**: no architecture change; the router's model ids stay configurable
  ([ADR 0021](adr/0021-model-router-and-builders.md)).

## OQ-20: Brand logos in the app

Status: open.
- **Question**: The old `ui/mac-audit-fixes` branch added third-party logos (Simple Icons) for connections, with old
  ADR 0016 still "proposed". Use them?
- **Recommended default**: monograms until each brand's guidelines are checked.
- **Affects**: Connections screen (M8).
