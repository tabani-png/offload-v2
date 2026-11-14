# 0037. Hosting: Offload Cloud and self-host at parity

Status: accepted · Date: 2026-11-14 · Owner decision [OQ-29](../OPEN_QUESTIONS.md#oq-29-hosting-offload-cloud-and-self-host)

## Context
The owner decided on 2026-11-14: "We'll make it self-hostable as well as the cloud hostable." Offload runs in two
ways: **Offload Cloud** (operated by consultance.ai) and **self-host** (operated by the customer). The plan split is
decided too ([OQ-13](../OPEN_QUESTIONS.md#oq-13-plan-contents-and-prices)): single-player core free, multiplayer paid.
If the two hosting modes drift, self-hosters get a second-class product, bugs appear in one mode only, and the license
boundary leaks (a feature that is "Cloud only" in code is a gate nobody wrote down). [ADR 0002](0002-stack-bun-typescript-hono-postgres.md)
already keeps self-host small: Postgres 17 plus S3-compatible object storage. [ADR 0023](0023-service-layout.md) keeps
one process (`offload serve`) plus the broker. This ADR fixes how both hosting modes stay the same product.

The specific cloud provider and region for Offload Cloud stays open
([OQ-01](../OPEN_QUESTIONS.md#oq-01-cloud-hosting-provider-and-region), default AWS `ca-central-1`).

## Decision

### One codebase, one image set
- One repository, one build, one set of images for both modes:
  - `offload`: one Linux image with the entry points `offload serve` (the api, brain, builder and runtime modules),
    `offload broker` (the credential broker, its own process, [ADR 0034](0034-credential-broker-and-key-providers.md)),
    `offload migrate` (schema migrations as `offload_migrator`) and `offload healthcheck`.
  - Sandbox base images for build workers ([ADR 0011](0011-sandboxed-build-workers.md)), the same digests for the
    `docker`, `container-use` and `e2b` providers.
- The Enterprise entry (`@offload-ee/server-ee`) ships in the same image. It runs only when selected
  (`offload serve --ee`) and entitles features only with a valid license key ([ADR 0015](0015-open-core-layout-and-license-gating.md)).
- Images are tagged with the release version and the commit, and published with their digests and an SBOM.

### Parity rules
1. **No code branches on where it runs.** No variable names the hosting mode, and no `if (cloud)` path exists. Every
   difference is configuration of a port: key provider (`aws-kms`, `gcp-kms`, `local`), sandbox provider (`e2b`,
   `docker`, `container-use`), identity provider (any OIDC issuer, magic link), object store (any S3-compatible
   endpoint), model provider (Anthropic, BYOK, optional local tier), telemetry (off by default).
2. **Every feature runs in both modes.** Core and EE features are the same in both; a feature is enabled by the
   license key, never by the hosting mode. What only Offload Cloud has are operations, not features: hosted upgrades
   and backups, Offload's own accounts (verified OAuth clients, the model provider account, the E2B account) and
   support. A self-hoster brings their own OAuth clients, model key and sandbox provider.
3. **Same versions and migrations.** Offload Cloud production runs only tagged releases. Every tag that reaches Cloud
   production is published for self-host at the same time. Migrations are the same files in both.
4. **Same verify suite.** The parity suite (below) runs against a compose deploy and against the Cloud deploy and must
   pass on both before a release is published.
5. **A port adapter is added in pairs or with contract tests.** A new adapter (for example a new key provider) passes
   the same contract tests as the existing ones before it ships.

### License key gating is identical in both modes
- `packages/license` verifies Ed25519-signed keys offline in both modes. No call home, no hosting-mode check.
- `OFFLOAD_EE_LICENSE_KEY` holds one key or several keys separated by whitespace, each with a distinct `plan`. Each
  verified key is a row in `license_state` ([DATA_MODEL.md](../DATA_MODEL.md#3-tenancy-and-identity)).
- A tenant's entitlements are the `features[]` of the verified, unexpired key whose `plan` equals `tenants.plan`.
  `plan = 'free'` has no EE features. This is one function in both modes.
- **Offload Cloud** loads its own keys, one per paid plan (a `pro` key with `teams`, an `enterprise` key with the
  Enterprise features). A tenant's `plan` comes from billing.
- **Self-host** loads the customer's key. With one key loaded, new tenants take that key's plan; with no key, `free`.
- Routes, `403 feature_not_licensed` on the EE root and `404` on the core root are the same in both modes.

### Self-host on one host: docker compose
`infra/docker-compose/compose.yaml` is the single-host path:
- `postgres`: Postgres 17 with pgvector, a named volume, a `pg_isready` health check.
- `objectstore`: an S3-compatible store (MinIO or another; see Consequences), a named volume, a health check;
  `objectstore-init` creates the bucket once.
- `migrate`: `offload migrate`, runs to completion before `serve` and `broker` start.
- `broker`: `offload broker`. The only service that gets the master key file (`local` key provider) as a compose
  secret. It listens on a Unix socket in a volume shared with `serve` only.
- `serve`: `offload serve`, the only published port, `GET /readyz` health check.
- `sandbox` (profile `builds`, optional): a separate Docker daemon for the `docker` sandbox provider, so build workers
  never get the host's Docker socket. `container-use` on Dagger is the alternative provider.
- No secret values in the file. Values come from `.env` (names in `.env.example`) and from files named by `*_FILE`
  variables.

### Self-host on Kubernetes: the Helm chart plan
`infra/helm/offload` (real templates in M8; a skeleton now):
- **Pods**: with the `file` key provider, one Deployment whose pod has two containers, `serve` and `broker`, joined by a Unix socket in an
  `emptyDir`, so the broker stays its own process with the same local-socket boundary as on one host
  ([ADR 0034](0034-credential-broker-and-key-providers.md)). The master key Secret is mounted into the broker
  container only. Limit: workload identity is per pod, so a KMS decrypt grant would cover both containers. With a KMS
  key provider the chart therefore runs the broker as its own Deployment with its own ServiceAccount, reached over a
  namespace-internal Service with the service token and mTLS, and a NetworkPolicy that admits only `serve` pods.
- **Values**: image repository, tag and digest; replicas and resources; key provider
  (`aws-kms`, `gcp-kms` or `file`); sandbox provider; OIDC issuer and client id; public base URL; ingress; telemetry
  (default `off`); retention days; `ee.enabled`.
- **Secrets**: never in values. Every secret is an `existingSecret` reference: database URL, object store keys,
  master key file, OIDC client secret, model provider key, sandbox provider key, license key.
- **External Postgres and S3 only.** The chart does not run Postgres or object storage; it needs Postgres 17 with
  pgvector and an S3-compatible bucket.
- **Key provider**: KMS through workload identity (no static cloud keys), or a master key file from a Secret mounted
  only into the broker container.
- **Ingress**: one host for the API and web app, TLS required, `serve` the only backend. The broker is never behind
  the ingress. A NetworkPolicy limits ingress to the ingress controller and egress to the services Offload needs.
- **Upgrades and migrations**: `offload migrate` as a Helm `pre-install` and `pre-upgrade` Job; then a rolling update
  of the pod.
- **Backups**: the chart does not own them. The docs give the plan: Postgres point-in-time recovery or scheduled
  `pg_dump`, bucket versioning, a restore rehearsal. An optional backup CronJob is a values switch, off by default.

### Telemetry
- Self-host sends **no telemetry by default** (`OFFLOAD_TELEMETRY=off`). Turning it on sends a daily, content-free
  report: version, migration head, enabled modules, bucketed counts of tenants and members, license `key_id` if any.
  No names, no tenant content, no hosts. The same log schema rules as Offload Cloud apply
  ([DEPLOYMENT section 8](../DEPLOYMENT.md#8-observability-without-content)).
- License verification never sends anything. Offload Cloud's own operational monitoring is not telemetry; it is the
  observability in DEPLOYMENT section 8.

### Upgrade and versioning policy
- Semantic versions `MAJOR.MINOR.PATCH` for the image, the chart and the API server. Before 1.0, a minor release may
  change behaviour; its upgrade notes say how.
- Migrations are forward only and expand then contract: a column is added in one release and old code paths removed in
  a later one, so the running version works during the migration
  ([DEPLOYMENT section 7.3](../DEPLOYMENT.md#73-deploy-pipeline)).
- Upgrades go one minor at a time. `offload migrate` refuses to skip a minor and says which release to install first.
- From 1.0: the latest and the previous minor get security fixes.
- The Mac client talks `/v1` to either mode. The server accepts the current and previous minor of the Mac client.

## Parity test list
Named for the M8 acceptance tests ([ROADMAP M8](../ROADMAP.md#m8-self-host-and-pro)):
- `PARITY: the same acceptance suite passes against the compose deploy and the cloud deploy`
- `PARITY: both deploys report the same version and migration head`
- `PARITY: the same license key gives the same features[] in GET /v1/me on both deploys`
- `PARITY: without a key, EE routes are 404 on the core entry and 403 feature_not_licensed on the EE entry, on both`
- `PARITY: no source file reads a variable that names the hosting mode`
- `PARITY: local and aws-kms key providers pass the same KeyProvider contract tests`
- `PARITY: docker and e2b sandbox providers pass the same SandboxProvider contract tests, egress allowlist and teeth gate included`
- `PARITY: the canary no-content-logging check passes on both deploys`
- `TELEMETRY: a compose deploy with default settings makes no telemetry request`
- `UPGRADE: a compose deploy of the previous minor upgrades in place and passes the suite`
- `BACKUP: a restore into a fresh compose deploy passes the suite`
- `HELM: helm template with default values renders and passes schema validation`

## Consequences
- Self-host is a first-class target from M1: the compose file grows with each service, and the cloud deploy uses the
  same image built by the same pipeline.
- The parity suite runs twice per release, which costs CI time.
- Offload Cloud cannot ship a hosted-only feature. Hosted value is operations, verified OAuth clients and support.
- MinIO is AGPL-3.0 and, as of late 2025, its maintainers stopped publishing free community images (verify before
  shipping). The compose file names the object store image as a placeholder; any S3-compatible store works, and the
  docs list alternatives.
- `license_state` holds one row per verified key, not one global row.

## Alternatives considered
- Cloud-only first, self-host later: the owner decided both.
- A separate self-host edition: two products to test.
- Online license checks: breaks air-gapped self-host and adds a phone-home path.
- A chart that bundles Postgres and MinIO: easy to start, hard to run safely; external services are required instead.

## Sources
Owner answer 2026-11-14 ([OQ-29](../OPEN_QUESTIONS.md#oq-29-hosting-offload-cloud-and-self-host)); Langfuse's one
codebase for OSS, EE self-host and Cloud ([OPEN_CORE.md](../OPEN_CORE.md#4-how-others-split)).
