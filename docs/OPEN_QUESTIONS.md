# Open questions for the owner

Decisions only Muhammad can make. Each has options and a **recommended default**. Agents build on the default; the
question stays here, marked, until he answers. Ordered by how much they block, most blocking first: by the earliest
milestone in the "Blocks" column (M0 first), then by how much of that milestone waits on it. New questions get the
next free id, so ids are not in order. When one is answered, write the answer under it, update the docs that cite it,
and add an ADR if it changes a decision. Decided questions keep their entry and id (nothing is renumbered) and move
to the end of the table.
Milestones are the ones in [ROADMAP.md](ROADMAP.md).

Status key: **open** (building on the default), **partly decided** (some parts answered, the rest open with
defaults), **Decided 2026-11-14 (owner)** (answered in the owner's own words, quoted under the question), **answered**
(settled by evidence or a standing rule).

Owner answers on 2026-11-14 (decision pass D): OQ-13 (plan split), OQ-16 (b) (Apple enrolment), and three new entries
for answers that had no question yet: OQ-27 (public repo), OQ-28 (masked text to the cloud), OQ-29 (hosting). They
also changed the defaults of OQ-25 (a public repo should not use a self-hosted runner for PR jobs) and the urgency of
OQ-11 (a public repo with no license grants no rights).

| # | Question | Status | Default or decision | Blocks |
|---|---|---|---|---|
| [OQ-16](#oq-16-mac-distribution-and-signing) | Mac distribution, signing, bundle id | partly decided: (b) enrolment | enrol as consultance.ai (decided, owner does it); Developer ID + notarized DMG + Sparkle; `ai.offload.mac` | M0 operator items, M3 |
| [OQ-25](#oq-25-ci-capacity-for-macos) | CI capacity for macOS | open, default revised | hosted `macos-26` for PRs and releases; no self-hosted runner on the public repo | M0 (CI `mac` job, O12) |
| [OQ-11](#oq-11-license-for-the-core-and-for-ee) | License for core and `ee/` | open | Apache-2.0 + commercial EE | the public push (operator), public release (M8) |
| [OQ-12](#oq-12-relicensing-code-from-the-old-repo) | Relicensing old-repo code | open | relicense under the v2 license | M1 (first port: audit chain writer in m1-03) |
| [OQ-06](#oq-06-identity-provider-for-offload-cloud) | Identity provider | open | one OIDC provider (Google) now; WorkOS AuthKit from M8 | M1 (login), M8 (WorkOS) |
| [OQ-01](#oq-01-cloud-hosting-provider-and-region) | Cloud provider and region for Offload Cloud | open (hosting modes decided in OQ-29) | AWS `ca-central-1` | M1 deploy (operator item O7) |
| [OQ-24](#oq-24-who-owns-the-oauth-clients) | Who owns the OAuth clients | open | consultance.ai Internal client now; verified client before outside users | M1 (login), M2 (connectors), M8 |
| [OQ-22](#oq-22-your-first-hand-fed-task-and-top-admin-drains) | Your first hand-fed task and top 5 admin drains | open | Stripe payouts → finance sheet (illustrative) | M2 |
| [OQ-05](#oq-05-model-provider-terms-and-monthly-model-budget) | Model provider terms, monthly budget | open | Anthropic API, standard retention, $50/month | M2 |
| [OQ-02](#oq-02-raw-ttl-for-masked-observations-in-the-cloud) | Cloud retention for masked observations and connector content | open | metadata 30 days, text 7 days, connector content 30 days | M2 (connector content), M3 (observations) |
| [OQ-21](#oq-21-drop-mutation-score-from-the-build-winner-rule) | Drop mutation score from the build winner rule | open | yes, dropped | M2 |
| [OQ-07](#oq-07-design-budget-before-ok-build) | Design budget before OK, build | open | $0.60 per opportunity | M2 |
| [OQ-08](#oq-08-sandbox-provider-for-cloud-builds) | Sandbox provider for cloud builds | open | E2B | M2 |
| [OQ-10](#oq-10-build-progress-screen-rows) | Build progress rows: check groups or workers | open | check groups | M2 (Build progress view) |
| [OQ-26](#oq-26-backfill-data-captured-before-upload-consent) | Upload days captured before consent | open | opt-in, off by default | M3 |
| [OQ-17](#oq-17-privacy-policy-terms-and-dpa) | Privacy policy, terms, DPA | open | lawyer-reviewed before any second user | M3 (screen 5 links), M8 |
| [OQ-03](#oq-03-keep-the-derived-user-model-long-term) | Keep the derived user model long term | open | yes, with controls | M5 |
| [OQ-04](#oq-04-keyframes-to-the-cloud) | Masked keyframes to the cloud | open | opt-in, off by default | M5 |
| [OQ-20](#oq-20-brand-logos-in-the-app) | Third-party brand logos in the app | open | monograms until reviewed | M5 (onboarding connect step) |
| [OQ-23](#oq-23-may-the-mac-client-run-deployed-fixes-locally) | Mac client runs device steps of deployed fixes | open | typed commands only, attended, per-step approval, from M6 | M6 |
| [OQ-09](#oq-09-graduation-threshold) | Graduation threshold | open | 5 clean runs + your OK | M6 |
| [OQ-14](#oq-14-optional-graphiti-adapter-and-graph-backend-licenses) | graphiti adapter in distribution | open | not shipped by default | M7 |
| [OQ-13](#oq-13-plan-contents-and-prices) | Plan contents and prices | partly decided: split | single-player core free, multiplayer paid via Pro (decided); prices open | M8 (prices, billing) |
| [OQ-15](#oq-15-monitoring-law-features-for-teams) | Per-person team features | open | Enterprise only, off by default | M8/M9 |
| [OQ-18](#oq-18-which-cortexa) | Which Cortexa did you mean | open | cortexa.network | none |
| [OQ-27](#oq-27-publish-the-repository-publicly) | Publish the repository publicly | Decided 2026-11-14 (owner) | public, as `tabani-png/offload-v2`; the operator pushes | none (operator pushes after the checklist) |
| [OQ-28](#oq-28-masked-screen-text-to-the-cloud) | Masked screen text to the cloud | Decided 2026-11-14 (owner) | yes; pixels stay on the Mac by default | none |
| [OQ-29](#oq-29-hosting-offload-cloud-and-self-host) | Hosting: Offload Cloud and self-host | Decided 2026-11-14 (owner) | both, at feature parity ([ADR 0037](adr/0037-hosting-cloud-and-self-host-parity.md)) | none |
| [OQ-19](#oq-19-what-is-fable-52-and-should-it-shape-the-architecture) | What is Fable 5.2 | answered | Claude Fable 5.2, dev-time only (architecture and review) | none |

## OQ-16: Mac distribution and signing

Status: **partly decided**. Sub-question (b) Decided 2026-11-14 (owner); (a) and (c) open.
- **Question**: How is the Mac client signed and distributed, and what is its bundle id?
- **Options**: ad-hoc signed builds for you only; Developer ID signed + notarized DMG with Sparkle updates; Mac App
  Store (sandboxing conflicts with Accessibility and screen capture needs).
- **Recommended default**: Developer ID + notarized DMG from CI, Sparkle with EdDSA signatures, bundle id
  `ai.offload.mac` (dev builds `ai.offload.mac.dev`). Signing is an M0 operator item, not an M8 task: macOS permission
  grants bind to the bundle id and Team ID, and a `swift build` binary is not an app bundle, so grants would reset on
  every rebuild. Needs an Apple Developer account for consultance.ai as an organisation (D-U-N-S number, days to weeks).
- **Sub-questions**:
  - (a) Bundle id domain: `ai.offload.mac` if you control `offload.ai`; otherwise an id under `consultance.ai`
    (for example `ai.consultance.offload.mac`). Default `ai.offload.mac`. Blocks M3 (first signed build).
  - (b) Apple Developer enrolment: who is the Account Holder. **Decided 2026-11-14 (owner)**: "Yes, enrol under
    consultance.ai". Enrolment is as the organisation consultance.ai. The owner does the enrolment himself and is the
    Account Holder (operator item O1). It starts now because the D-U-N-S number has a lead time of days to weeks. Agents
    do nothing for this item except keep the docs ready for the Team ID.
  - (c) A staging build id `ai.offload.mac.internal`, added before any second user
    ([DEPLOYMENT section 12](DEPLOYMENT.md#12-environments)). Default yes. Blocks M8.
- **Affects**: [ADR 0024](adr/0024-client-stacks.md), [DEPLOYMENT.md](DEPLOYMENT.md), operator items O1 to O3 and O11.

## OQ-25: CI capacity for macOS

Status: open, **default revised 2026-11-14** because the repository will be public ([OQ-27](#oq-27-publish-the-repository-publicly)).
- **Question**: Where do the macOS CI jobs run? Hosted macOS minutes cost about ten times Linux minutes, and the old
  repo ran out of them.
- **Options**: hosted macOS runners only; a dedicated self-hosted Mac for PR jobs with hosted `macos-26` for releases
  (the previous default, PR #42's recommendation, which assumed a private repo).
- **Recommended default (revised)**: hosted `macos-26` for PR jobs and releases. On a public repository GitHub's
  standard hosted runners are free, so the cost reason for a self-hosted Mac goes away (check GitHub's current billing
  page before relying on it). GitHub advises against self-hosted runners on public repositories, because a pull request
  from a fork can run code on the runner. If a self-hosted Mac is used at all, it runs only manually triggered jobs from
  `main` (for example the macOS 14 checks), never `pull_request` jobs. Hosted macOS 14 images were retired on
  2026-11-02, so the macOS 14 minimum is tested on a local Mac. Keep macOS 14 as the minimum.
- **Blocks**: M0 (CI `mac` job), operator item O12.
- **Affects**: `.github/workflows/ci.yml`, [DEPLOYMENT section 6](DEPLOYMENT.md#6-ci).

## OQ-11: License for the core and for EE

Status: open. **More urgent since 2026-11-14**: the repository will be public ([OQ-27](#oq-27-publish-the-repository-publicly)).
- **Question**: Which licenses?
- **Options**: core Apache-2.0, MIT, AGPL-3.0, or fair-code (Sustainable Use); EE commercial (Langfuse style) or BSL.
- **Recommended default**: **Apache-2.0 core** (patent grant) + **commercial Offload Enterprise License for `ee/`**,
  source-visible, production use needs a key.
- **Blocks**: the public push, in practice. Pushing with the placeholder `LICENSE` is possible, but then the code is
  visible and nobody may use, copy or contribute to it: public is not open source. Recommended: answer before the
  operator pushes, or push knowingly with the placeholder.
- **Affects**: `LICENSE`, `ee/LICENSE`, [OPEN_CORE.md](OPEN_CORE.md#1-license).

## OQ-12: Relicensing code from the old repo

Status: open.
- **Question**: The old repo is "all rights reserved" (yours). May its code be relicensed under the v2 license when
  ported?
- **Options**: yes for everything; yes except named parts; no (rewrite clean-room).
- **Recommended default**: yes for everything you wrote. Third-party pieces keep their own licenses in `NOTICE`.
- **Blocks**: M1. The first port is the audit chain writer (old `control/src/audit`) in slice
  [m1-03](../slices/m1-03-tenancy-rls/SPEC.md); the Mac capture port follows in M3.
- **Note**: publishing the repo ([OQ-27](#oq-27-publish-the-repository-publicly)) does not need this answer while no
  old-repo code is ported; the docs describe old code but do not copy it. The first port does.
- **Affects**: every port in [MIGRATION.md](MIGRATION.md).

## OQ-06: Identity provider for Offload Cloud

Status: open.
- **Question**: Which login for Offload Cloud?
- **Options**: one OIDC provider directly (Google, through your Workspace); email magic link; WorkOS AuthKit (old
  ADR 0102; SSO and SCIM later); Clerk; Auth0; self-run (Keycloak, Zitadel).
- **Recommended default**: M1 uses one OIDC provider, Google, through the OAuth client from operator item O5 (magic link
  for self-hosters). WorkOS AuthKit arrives with Pro in M8, used only as an OIDC issuer from core; SAML and SCIM through
  WorkOS in EE on Cloud. Core stays vendor-free.
- **Affects**: [ADR 0014](adr/0014-identity.md), slice [m1-04](../slices/m1-04-login-devices/SPEC.md).

## OQ-01: Cloud hosting provider and region

Status: open. The hosting **modes** are decided (Offload Cloud and self-host at parity,
[OQ-29](#oq-29-hosting-offload-cloud-and-self-host)); the provider and region for Offload Cloud stay open with this
default.
- **Question**: Where does Offload Cloud run first?
- **Options**: (a) AWS `ca-central-1` (Montreal): managed Postgres 17 with pgvector, S3, KMS, Canadian residency.
  (b) GCP `northamerica-northeast2` (Toronto). (c) Fly.io / Render / Railway: simpler, weaker KMS and residency story.
  (d) A Hetzner box: cheapest, most ops work.
- **Recommended default**: (a) AWS `ca-central-1`. You are in Toronto; Canadian data residency helps later Canadian
  customers; KMS and RDS cover the envelope-encryption and backup design.
- **Affects**: [ARCHITECTURE section 15](ARCHITECTURE.md#15-deployment), [SECURITY_PRIVACY.md section 10](SECURITY_PRIVACY.md#10-sub-processors), operator item O7.

## OQ-24: Who owns the OAuth clients?

Status: open.
- **Question**: Who owns the OAuth clients for Google (Gmail, Calendar, Sheets, Drive) and for login?
- **Options**: (a) consultance.ai's own Internal client now, and a verified external client before any outside user;
  (b) Composio's managed auth for Google; (c) mixed.
- **Recommended default**: (a). An Internal client for the tenant of one (operator item O5); start Google verification
  before Pro, because restricted scopes need a security assessment that takes weeks. Composio only for apps with no
  client of our own.
- **Blocks**: M1 (login), M2 (connectors), M8 (outside users).
- **Affects**: [ADR 0014](adr/0014-identity.md), [ADR 0033](adr/0033-pinned-connector-resolution-and-launch-catalog.md),
  [DEPLOYMENT.md](DEPLOYMENT.md) operator item O5.

## OQ-22: Your first hand-fed task and top admin drains

Status: open.
- **Question**: M2 proves the build and run half on one task you type in. Which task? And what are your top 5 admin
  drains, so the M5 fixtures look like your real week?
- **Options**: any repeated task that touches two apps Offload can connect on day one (see the launch catalog in
  [ADR 0033](adr/0033-pinned-connector-resolution-and-launch-catalog.md)).
- **Recommended default**: "copy Stripe payouts into the finance sheet every week" (Stripe API with a restricted read
  key, Google Sheets through your internal OAuth client). This is illustrative: the persona details and job examples in
  [PRODUCT.md](PRODUCT.md#3-jobs-to-be-done) are not from your data. Please confirm or replace them.
- **Affects**: [ROADMAP M2](ROADMAP.md#m2-hand-fed-loop), PRODUCT.md personas and jobs.

## OQ-05: Model provider terms and monthly model budget

Status: open.
- **Question**: Which provider account and data terms for model calls, and what monthly cap for your tenant?
- **Options**: Anthropic API with standard retention; Anthropic with zero data retention (some models unavailable);
  BYOK per tenant; Bedrock/Vertex.
- **Recommended default**: Anthropic API, standard retention, masked and pseudonymised text only, for your tenant of
  one; **$50/month** cap (builds are capped separately at $4.00 each and count toward it). Zero data retention is an
  operator item (O10) with a lead time and must be in place before any second user. The router allowlists the product
  models (Opus, Sonnet, Haiku); per PR #42, Fable and Mythos are not available under zero retention. BYOK is a default (an
  open sub-question of [OQ-13](#oq-13-plan-contents-and-prices)).
- **Note**: onboarding screen 5 names Anthropic as the model provider and says "Offload doesn't sell your data". Any
  "not used for training" or zero-retention wording waits on operator item O10.
- **Affects**: [ADR 0021](adr/0021-model-router-and-builders.md), `tenants.monthly_model_budget_usd`.

## OQ-02: Raw TTL for masked observations in the cloud

Status: open. That masked text is uploaded at all is decided ([OQ-28](#oq-28-masked-screen-text-to-the-cloud)); how long it stays is not.
- **Question**: How long does masked and connector data stay in the cloud before deletion? Three numbers:
  C1 metadata (focus, titles, hosts, idle), C1 text snapshots (masked screen text), and C6 connector content (fixture
  reads and instant reads).
- **Options**: metadata 7, 30 or 90 days; text 7 or 30 days; connector content 7, 30 or 90 days.
- **Recommended default**: **metadata 30 days, text 7 days, connector content 30 days**. Metadata long enough to rebuild a
  month of records after a bug fix; text short because it is the most sensitive upload; connector content long enough
  for a rebuild without asking you to reconnect, and a later rebuild simply re-runs fixture capture. The constants are
  `OFFLOAD_RAW_TTL_DAYS`, `OFFLOAD_TEXT_TTL_DAYS`, `OFFLOAD_CONTENT_TTL_DAYS`; code never hard-codes them.
- **Affects**: [DATA_MODEL.md](DATA_MODEL.md#1-conventions) `R-raw`, `R-text`, `R-content`, onboarding copy, slice
  [m3-01](../slices/m3-01-ingest-batches/SPEC.md).

## OQ-21: Drop mutation score from the build winner rule

Status: open.
- **Question**: Your brief says a winner among fan-out attempts is picked by held-out pass, then mutation score, then
  smallest diff. The bench found mutation-score picking did not pick the better build (4 of 6 winners passed
  held-out), and PR #45 removed mutation scoring. May we drop it?
- **Options**: (a) drop it: replay and held-out pass, then smallest diff; (b) keep it as the second key.
- **Recommended default**: (a). It also removes mutation sandboxes from the $4.00 worst case.
- **Affects**: [ADR 0029](adr/0029-build-verdicts.md), [ADR 0012](adr/0012-builder-policy-one-worker-held-out-fan-out.md).

## OQ-07: Design budget before OK, build

Status: open.
- **Question**: How much may Offload spend on fixture capture, the brief, the check set and the held-out check before
  you press OK, build? (This is outside the $4.00 build cap you set.)
- **Options**: $0.30, $0.60, $1.00 per opportunity.
- **Recommended default**: **$0.60** (bench: check writing cost about $0.11 per brief; held-out about $0.10; Opus
  wording on top). A retry build regenerates the held-out check from this budget.
- **Affects**: [ADR 0012](adr/0012-builder-policy-one-worker-held-out-fan-out.md).

## OQ-08: Sandbox provider for cloud builds

Status: open.
- **Question**: Which sandbox runs cloud builds?
- **Options**: E2B (Firecracker microVMs, Apache-2.0 SDK, hosted); self-run Firecracker; Modal; Daytona (archived
  July 2026, avoid); Claude Managed Agents sandboxes.
- **Recommended default**: E2B, behind the `SandboxProvider` port, with prebuilt images and no registry access. M2
  starts on the Docker provider and moves to E2B before its exit.
- **Affects**: [ADR 0011](adr/0011-sandboxed-build-workers.md), sub-processor list, operator item O6.

## OQ-10: Build progress screen rows

Status: open.
- **Question**: The approved mockup shows 8 named workers, each in its own sandbox. The bench decision is one worker
  by default, more only on failure. What should the rows be?
- **Options**: (a) rows are **check groups** inside one worker, with worker tabs appearing only on fan-out; (b) keep
  8 worker rows (not true to how it runs).
- **Recommended default**: (a). Same look, honest about the mechanics. Copy says "each in its own sandbox" only when
  fan-out happens.
- **Affects**: [PRODUCT.md section 6](PRODUCT.md#6-ui-direction), Build progress view (M2 on the web, Mac in M5).

## OQ-26: Backfill data captured before upload consent?

Status: open.
- **Question**: When you first choose **Start sending**, may Offload upload the local days captured before that
  (up to 7 days in the local buffer)?
- **Options**: never; opt-in "Include the last few days"; automatic.
- **Recommended default**: opt-in, off by default ([ONBOARDING screen 5](ONBOARDING.md#screen-5-what-leaves-your-mac)).
- **Blocks**: M3.
- **Affects**: the uploader in slice [m3-02](../slices/m3-02-mac-capture-upload/SPEC.md), `consents`.

## OQ-17: Privacy policy, terms and DPA

Status: open.
- **Question**: Offload's own privacy policy, terms and DPA with sub-processors.
- **Recommended default**: draft from [SECURITY_PRIVACY.md](SECURITY_PRIVACY.md) and have a lawyer review before any
  user other than you. Include the Composio retention disclosure and the honest limits.
- **Note**: the "What leaves your Mac" screen ([ONBOARDING screen 5](ONBOARDING.md#screen-5-what-leaves-your-mac))
  links to the privacy policy and terms, so a plain-language version for you is needed by M3 (operator item O15);
  the lawyer-reviewed version is needed before any second user.
- **Hosting**: the policy and DPA cover Offload Cloud. A self-hoster runs their own deployment and is responsible for
  their own data ([OQ-29](#oq-29-hosting-offload-cloud-and-self-host)); Offload receives nothing from it unless they
  turn on telemetry.
- **Affects**: M3 copy (screen 5 links), M8 exit.

## OQ-03: Keep the derived user model long term

Status: open.
- **Question**: May Offload keep derived data (episodes, records, entities, facts, propositions; no raw screen data)
  after raw data expires? The old README promised everything older than 7 days is deleted.
- **Options**: (a) yes, until you forget it, with export/forget/pause controls; (b) cap at 12 months; (c) no.
- **Recommended default**: (a), with onboarding copy that says so plainly and the forget controls in Settings. The
  weekly, monthly and quarterly review depends on it. You already allowed a long-term profile with no raw screen data.
- **Affects**: [ADR 0019](adr/0019-user-model-storage.md), `R-model`.

## OQ-04: Keyframes to the cloud

Status: open. Not changed by [OQ-28](#oq-28-masked-screen-text-to-the-cloud): that answer covers masked text only; pixels stay on the Mac by default.
- **Question**: Should masked keyframes ever leave the Mac (for captioning by Haiku)?
- **Options**: (a) never; (b) opt-in per user (`keyframes_to_cloud`), default off; (c) on by default.
- **Recommended default**: (b), default off. Understanding works from metadata and masked text; images are an
  optional quality boost.
- **Affects**: [ADR 0005](adr/0005-masked-text-only-reaches-models.md), [SECURITY_PRIVACY.md section 3](SECURITY_PRIVACY.md#3-what-leaves-the-mac).

## OQ-20: Brand logos in the app

Status: open.
- **Question**: The old `ui/mac-audit-fixes` branch added third-party logos (Simple Icons) for connections, with old
  ADR 0016 still "proposed". Use them?
- **Recommended default**: monograms until each brand's guidelines are checked.
- **Affects**: the connect step in Mac onboarding (screen 10, M5) and the Connections screens (M5 Mac, M8 web).

## OQ-23: May the Mac client run deployed fixes locally?

Status: open.
- **Question**: Some fixes act on your Mac (a Shortcut, an Apple Event, an Accessibility action, an attended browser
  step). May the Mac client run those device steps through the actuator?
- **Options**: (a) never: cloud only; (b) typed commands only (Shortcut, reviewed Apple Event template, Accessibility
  action, attended browser step), attended, approved per step, from M6; (c) as (b), plus unattended device steps after
  graduation.
- **Recommended default**: (b), as [ADR 0025](adr/0025-execution-placement-and-mac-actuator.md) assumes. Cloud only
  until M6. You confirm because it changes what Offload may do on your Mac.
- **Blocks**: M6 (actuator).
- **Affects**: [ARCHITECTURE section 12](ARCHITECTURE.md#12-execution-placement-and-the-mac-actuator),
  [API.md section 4](API.md#4-device-commands), fix kinds `script` and `browser_automation`.

## OQ-09: Graduation threshold

Status: open.
- **Question**: When may a routine stop asking before each commit?
- **Options**: never by default; after N clean runs with your one-tap OK; after N clean runs automatically.
- **Recommended default**: after **5 consecutive approved runs with no edits and no failed or unknown items**, Offload
  proposes it and you confirm with one tap. Browser-automation commits keep asking.
- **Affects**: [ADR 0016](adr/0016-no-dry-run.md), [ARCHITECTURE section 11](ARCHITECTURE.md#11-routine-runtime).

## OQ-14: Optional graphiti adapter and graph backend licenses

Status: open.
- **Question**: Ship a graphiti adapter? Its backends include FalkorDB (source-available, SSPL-style terms), Neo4j
  Community (GPLv3) and Amazon Neptune (managed service); Kuzu is reported archived (verify before citing).
- **Options**: (a) Postgres only, no adapter; (b) adapter as an optional plug-in the self-hoster installs, not in our
  images; (c) ship FalkorDB in our images.
- **Recommended default**: (b). Default distribution is Postgres only.
- **Affects**: [ADR 0019](adr/0019-user-model-storage.md).

## OQ-13: Plan contents and prices

Status: **partly decided**. The split is **Decided 2026-11-14 (owner)**: "One person free, teams pay." Prices and
the sub-questions below stay open with their defaults.
- **Question**: What is free, what is Pro, what is Enterprise, and what do Pro and Enterprise cost? (Pricing page v3
  labels prices as proposals. These docs set no prices.)
- **Options**:
  - (a) **Single-player is core, multiplayer is paid.** Core is everything one person needs, self-host included. Team
    tenants (`kind = 'team'`: invites, workspaces, shared fixes, team review) live in `ee/packages/teams` and are
    enabled by the Offload Cloud key for Pro. Enterprise adds SSO/SCIM, approval chains, Cedar custom policies, SIEM,
    an external audit anchor sink, BYOC and support. One gate (team tenant creation), easy to enforce; a hosted clone
    of the core gets only the single-player product.
  - (b) **Hosting-only Pro** (the previous default): all features except EE governance are core; Pro is Offload Cloud
    hosting plus budgets. Weak: with an Apache-2.0 core anyone can host the same thing.
  - (c) **Fair-code core** (n8n's Sustainable Use License): protects hosting, but the core is no longer OSI open source,
    which you asked for.
- **Decision**: option (a). Single-player core is free. Multiplayer (team tenants, invites, workspaces, shared fixes,
  team review) is paid through Pro. Enterprise adds SSO/SCIM, approval chains, SIEM and audit export, BYOC and support.
  Options (b) and (c) are closed. Both plans run on Offload Cloud and self-host, switched on by a license key
  ([ADR 0037](adr/0037-hosting-cloud-and-self-host-parity.md)). Recorded in [OPEN_CORE.md](OPEN_CORE.md#2-feature-split)
  and [ADR 0015](adr/0015-open-core-layout-and-license-gating.md).
- **Still open**: the prices of Pro and Enterprise. Enterprise items beyond the owner's list (custom Cedar policies,
  external audit anchor sink, legal hold, configurable retention, dedicated deployment) are Enterprise by default.
- **Sub-questions** (open; each has a default in OPEN_CORE.md):
  - (a) Is there a free hosted tier on Offload Cloud, and who pays its model and sandbox costs? Default: no free hosted
    tier beyond your own tenant; free means self-host. Your words "One person free" could also mean a free hosted
    tier for one person; please confirm which.
  - (b) What exactly is in Pro? Decided in outline (multiplayer). Default extras: onboarding help for teams new to AI,
    higher budgets, and a Pro key for self-hosters (parity).
  - (c) How are seats enforced? Default: warn when over, block new invites after 30 days, never block existing members
    or safety features.
  - (d) Support tiers? Default: community (Free), email (Pro), SLA (Enterprise).
  - Also: team size for Pro (default 3 to 20) and BYOK for every tenant (default yes).
- **Affects**: OPEN_CORE.md, [ADR 0015](adr/0015-open-core-layout-and-license-gating.md), web app billing (M8).

## OQ-15: Monitoring-law features for teams

Status: open.
- **Question**: Do per-person views and working time exist at all for teams, and in which plan?
- **Options**: not at all; Enterprise only with compliance records (old ADR 0108); Pro and Enterprise.
- **Recommended default**: Enterprise only, off by default, owner enablement with DPIA attestation and notice period.
  Workflow-level metrics with a group floor of 5 are available to all team plans.
- **Affects**: [SECURITY_PRIVACY.md section 12](SECURITY_PRIVACY.md#12-compliance-notes-not-legal-advice).

## OQ-18: Which Cortexa

Status: open.
- **Question**: The research Page assumed Cortexa Labs (Paladin: policy checks on every agent tool call, signed
  receipts). The brief names "Cortexa(.network)", and the repo-scout log rates cortexa.network (process intelligence,
  operations graph, governed flows) the best match. Which did you mean?
- **Recommended default**: **cortexa.network**, as the brief says. We borrow only patterns: an operations graph and
  governed flows ([ADR 0017](adr/0017-policy-engine-cedar.md)). No code. "A rule id on every decision" comes from the
  research Page, not from either Cortexa.
- **Affects**: nothing blocking.

## OQ-27: Publish the repository publicly

Status: **Decided 2026-11-14 (owner)**.
- **Question**: Should the v2 repository be published, and public or private?
- **Answer** (owner's words): "Yes, create a public repo and push".
- **Decision**: the repository is published **public** as `tabani-png/offload-v2`. The operator (the owner) creates it
  and pushes later. Agents still never create a remote, push or use `gh` ([CLAUDE.md](../CLAUDE.md)).
- **Consequences**:
  - A public repo with the placeholder `LICENSE` grants no rights, so [OQ-11](#oq-11-license-for-the-core-and-for-ee)
    is now urgent.
  - CI: no self-hosted runner for PR jobs on a public repo ([OQ-25](#oq-25-ci-capacity-for-macos), default revised).
  - The whole git history becomes public. The pre-publish checklist is in
    [DEPLOYMENT section 6.5](DEPLOYMENT.md#65-before-the-public-push).
- **Affects**: [README.md](../README.md), [DEPLOYMENT.md](DEPLOYMENT.md#65-before-the-public-push), operator item O4.

## OQ-28: Masked screen text to the cloud

Status: **Decided 2026-11-14 (owner)**.
- **Question**: May masked, pseudonymised screen text leave the Mac for the cloud brain? (The docs assumed yes,
  [ADR 0007](adr/0007-cloud-brain-thin-mac-client.md); the owner had not said it in so many words.)
- **Answer** (owner's words): "Yes, masked text can go to the cloud".
- **Decision**: masked text snapshots are uploaded after upload consent, as in
  [SECURITY_PRIVACY section 3](SECURITY_PRIVACY.md#3-what-leaves-the-mac). Pixels still stay on the Mac by default.
  Masked keyframes stay opt-in and off by default ([OQ-04](#oq-04-keyframes-to-the-cloud), still open). How long text
  stays is still [OQ-02](#oq-02-raw-ttl-for-masked-observations-in-the-cloud).
- **Affects**: [ADR 0005](adr/0005-masked-text-only-reaches-models.md), [ADR 0007](adr/0007-cloud-brain-thin-mac-client.md),
  [SECURITY_PRIVACY.md](SECURITY_PRIVACY.md#3-what-leaves-the-mac), [ONBOARDING screen 5](ONBOARDING.md#screen-5-what-leaves-your-mac).

## OQ-29: Hosting: Offload Cloud and self-host

Status: **Decided 2026-11-14 (owner)**.
- **Question**: Is Offload hosted by consultance.ai, self-hosted by customers, or both?
- **Answer** (owner's words): "We'll make it self-hostable as well as the cloud hostable".
- **Decision**: both, at **feature parity**: one codebase and one image set; docker compose for one host and a Helm
  chart for Kubernetes; `ee/` gated by the same license key mechanism in both (Offload Cloud uses its own key per
  tenant plan; self-host uses the customer's key); telemetry off by default for self-host. Recorded in
  [ADR 0037](adr/0037-hosting-cloud-and-self-host-parity.md).
- **Still open**: the cloud provider and region for Offload Cloud ([OQ-01](#oq-01-cloud-hosting-provider-and-region),
  default AWS `ca-central-1`).
- **Affects**: [DEPLOYMENT.md](DEPLOYMENT.md#11-self-host), [OPEN_CORE.md](OPEN_CORE.md), `infra/docker-compose`,
  `infra/helm/offload`, [ROADMAP M8](ROADMAP.md#m8-self-host-and-pro).

## OQ-19: What is Fable 5.2 and should it shape the architecture?

Status: **answered** (owner's standing rule, 2026-11-14).
- **Question**: You mentioned "Fable 5.2" when asking for this work.
- **Answer**: Claude Fable 5.2 (`claude-fable-5-2`) is a Claude model. All building in this repo is done with Claude
  Code: Opus for architecture, design and review, Sonnet for implementation, and Fable 5.2 allowed for architecture
  and review work. Claude Code is signed into your subscription by default with `ANTHROPIC_API_KEY` unset; the API key
  is used only where the operator allows it (parallel workers). Recorded in
  [AGENTS.md](../AGENTS.md#model-and-tool-usage) and [CLAUDE.md](../CLAUDE.md).
- **Consequences**: no architecture change. Fable is a dev-time model only, never a product route: per PR #42, Claude
  Fable and Mythos models are excluded from Anthropic zero data retention, so product routing stays Opus, Sonnet and
  Haiku ([ARCHITECTURE section 17](ARCHITECTURE.md#17-model-router),
  [ADR 0021](adr/0021-model-router-and-builders.md)).
