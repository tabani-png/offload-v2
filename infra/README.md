# infra

Offload runs as **Offload Cloud** and as **self-host**, with the same image and the same features
([ADR 0037](../docs/adr/0037-hosting-cloud-and-self-host-parity.md)). Both definitions here are skeletons: there is no
feature code and no published image yet.

- `docker-compose/compose.yaml`: one-host self-host and local development. Postgres 17 + pgvector, an S3-compatible
  store (placeholder image) with a bucket init job, `offload migrate`, `offload broker`, `offload serve`, and an
  optional sandbox Docker daemon (profile `builds`). Health checks on every long-running service; no secret values;
  environment from `.env` (names in [.env.example](../.env.example)).
- `helm/offload/`: Kubernetes self-host. `Chart.yaml`, a `values.yaml` skeleton, placeholder templates that render
  nothing until M8, and a [README](helm/offload/README.md). External Postgres and S3 only.

Self-host needs only Postgres 17 with pgvector and S3-compatible object storage, plus a key provider, an OIDC client
(or magic link), a model key and a sandbox provider. Steps: [DEPLOYMENT section 11](../docs/DEPLOYMENT.md#11-self-host).
