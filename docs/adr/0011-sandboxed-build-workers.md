# 0011. Sandboxed build workers

Status: accepted · Date: 2026-11-14 · Supersedes old ADR 0013 (proposed, never implemented)

## Context
Old ADR 0013 found that `sandbox-exec` under the same macOS user cannot stop builder code from reading other
processes' argv and environment through `sysctl KERN_PROCARGS2`. Re-checked on macOS 26.5.1 on 2026-10-26: a same-user
`bun` returned 61 env entries of another process. So no build may run on a machine that holds secrets in other
processes. v2 builds in the cloud ([ADR 0007](0007-cloud-brain-thin-mac-client.md)).

## Decision
- A **`SandboxProvider` port** in `services/builder`: `create(spec) → sandbox`, `exec`, `putFiles`, `getFiles`,
  `snapshot`, `destroy`. Spec includes image, CPU, memory, wall time, network allowlist.
- **Offload Cloud: E2B** (Apache-2.0 SDK; Firecracker microVMs). One microVM per worker attempt. Destroyed after.
- **Self-host and dev: container-use on Dagger** (Apache-2.0, one container and git branch per agent), or plain
  **Docker** with `--network none --read-only --cap-drop ALL` and a tmpfs workspace. Choice by `OFFLOAD_SANDBOX_PROVIDER`
  (`e2b`, `container-use`, `docker`).
- Hard rules for every provider:
  - **One sandbox per worker attempt**, nothing else running inside it as another tenant or user.
  - **No secrets inside**: no API keys, no connector credentials. Model calls from the worker go through an egress
    proxy that adds the key outside the sandbox.
  - **Network deny by default**. Allowed: the model egress proxy, and the package registries listed in the brief, through
    a filtering proxy. Nothing else.
  - **Checks are immutable**: check files are mounted read-only; their hash (tamper hash) is checked before and after
    every attempt. A mismatch ends the build as `tampered`.
  - **Nonce proof**: the trusted harness runs the checks in a child process and prints a final `OFFLOAD_PROOF` line with
    the runner's nonce. Exit code 0 alone is never a pass.
  - Resource caps: 2 vCPU, 4 GiB RAM, 12 minutes wall per attempt (defaults; per-plan values in policy).
- Fixture replay and held-out checks run in a **fresh** sandbox from the attempt's artifact, never in the worker's
  own sandbox.

## Consequences
- The same-uid leak class does not apply: the worker is the only principal in its VM and the VM holds no secrets.
- Cloud builds send the brief, masked fixtures and the user's code context (if any) to E2B. E2B is a sub-processor
  ([SECURITY_PRIVACY.md](../SECURITY_PRIVACY.md#10-sub-processors)). Provider choice is [OQ-08](../OPEN_QUESTIONS.md#oq-08-sandbox-provider-for-cloud-builds).
- Setup fixes that edit Claude Code settings (`.claude/`) hit Claude Code's write wall in non-bypass modes (bench
  finding). Those are `setup_change` fixes delivered as a reviewed config patch, not built by a worker.

## Alternatives considered
- Apple Containerization microVM on the user's Mac (old ADR 0013 option B): needs macOS 26 on Apple silicon; still on
  the user's machine. Kept as a possible local tier later.
- Hidden user + root helper (old option A): complex, still same machine.
- Managed Agents sandboxes for builds: possible later behind the same port.

## Sources
Old ADR 0013; old `brain/src/builder/{sandbox,supervisor,harness}.ts`; `/workspace/offload-bench/README.md`.
