# infra

- `docker-compose/compose.yaml`: Postgres 17 + pgvector for local dev and the smallest self-host.
- `helm/offload/`: placeholder chart for self-host on Kubernetes. Templates arrive with the services.

Self-host needs only Postgres and S3-compatible object storage. See [ARCHITECTURE section 14](../docs/ARCHITECTURE.md#14-deployment).
