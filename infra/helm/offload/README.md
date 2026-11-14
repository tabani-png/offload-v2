# Offload Helm chart (skeleton)

Self-host Offload on Kubernetes. **Skeleton only**: the templates are placeholders that render nothing until the
services exist (M8). The plan is in [DEPLOYMENT section 11](../../../docs/DEPLOYMENT.md#11-self-host) and
[ADR 0037](../../../docs/adr/0037-hosting-cloud-and-self-host-parity.md).

## What it will deploy

| Template | Workload |
|---|---|
| `serve-deployment.yaml` | `offload serve` (api, brain, builder, runtime modules); with the `file` key provider also an `offload broker` container in the same pod, joined by a Unix socket, the only container that gets the master key Secret |
| `broker-deployment.yaml` | With a KMS key provider: the broker as its own Deployment and ServiceAccount, so only it holds the KMS decrypt grant (workload identity is per pod) |
| `migrate-job.yaml` | `offload migrate`, a `pre-install` and `pre-upgrade` hook Job |
| `service.yaml` | The `serve` Service (HTTP); a namespace-internal broker Service only with a KMS key provider |
| `ingress.yaml` | One TLS host for the API and the web app |
| `networkpolicy.yaml` | Ingress to `serve` from the ingress controller only; to a separate broker from `serve` only; egress to the services Offload needs |
| `serviceaccount.yaml` | Workload identity for KMS and S3 |
| `backup-cronjob.yaml` | Optional `pg_dump` to the bucket, off by default |

## Requirements

- Postgres 17 with pgvector, reachable from the cluster (the chart does not run Postgres).
- An S3-compatible bucket with versioning (the chart does not run object storage).
- A key provider: a KMS key through workload identity, or a 32-byte master key in a Secret.
- An OIDC client of your own, or magic link with an email sender.
- A model provider key of your own, or the optional local tier.
- A sandbox provider: an E2B key, or an isolated Docker or container-use daemon.

## Rules

- No secret in `values.yaml`. Each secret is an `existingSecret` reference.
- Same image, same features and same license key mechanism as Offload Cloud.
- Telemetry is off unless `telemetry.enabled` is true.
- Upgrades go one minor release at a time; the migrate Job refuses to skip one.
