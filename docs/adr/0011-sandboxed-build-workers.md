# 0011. Sandboxed build workers

Status: accepted, revised 2026-11-14 · Date: 2026-11-14 · Supersedes old ADR 0013 (proposed, never implemented)

## Context
Old ADR 0013 found that `sandbox-exec` under the same macOS user cannot stop builder code from reading other
processes' argv and environment through `sysctl KERN_PROCARGS2`. Re-checked on macOS 26.5.1 on 2026-10-26: a same-user
`bun` returned 61 env entries of another process. So no build may run on a machine that holds secrets in other
processes. v2 builds in the cloud ([ADR 0007](0007-cloud-brain-thin-mac-client.md)). The same lesson applies inside a
sandbox: the worker agent has Bash as the same uid as anything else in its VM.

## Decision
- A **`SandboxProvider` port** in the builder module: `create(spec) → sandbox`, `exec`, `putFiles`, `getFiles`,
  `snapshot`, `destroy`, `list(tag)`. Spec includes image, CPU, memory, wall time, network allowlist and a tag
  `offload-build-<build_id>` that the reaper uses ([ADR 0031](0031-build-infrastructure-failures.md)).
- Providers, chosen by `OFFLOAD_SANDBOX_PROVIDER`:
  - `e2b`: **Offload Cloud** (Apache-2.0 SDK; Firecracker microVMs). One microVM per sandbox. Destroyed after.
  - `docker`: self-host and dev, `--network none --read-only --cap-drop ALL`, tmpfs workspace.
  - `container-use`: self-host and dev (container-use on Dagger, Apache-2.0; one container and git branch per agent).
  - `apple-container`: **dev only**, on a dedicated build Mac that holds no user secrets (apple/container, as used for
    check shards in PR #45). Never the user's own Mac.
- Hard rules for every provider:
  - **One sandbox per worker attempt**, nothing else running inside it as another tenant or user.
  - **No secrets inside**: no API keys, no connector credentials. Model calls go through the model egress proxy, which
    adds the key outside the sandbox and enforces the budget ([ADR 0030](0030-build-budget-at-egress-proxy.md)).
  - **Network deny by default.** Allowed: the model egress proxy only. **No package registry access**: workers run on
    prebuilt images with a pinned dependency set per language (spike S4), because sandboxes hold fixture data.
  - **Fixtures are tokenised** before they enter any sandbox; the token map never does ([ADR 0027](0027-fixture-capture-and-connector-content.md)).
  - **Checks are immutable**: check files are mounted read-only; their hash (tamper hash) is checked before and after
    every attempt. A mismatch ends the build as `tampered`.
  - **Nonce proof**: the trusted harness runs the checks in a child process and prints a final `OFFLOAD_PROOF` line with
    the runner's nonce. Exit code 0 alone is never a pass.
  - Resource caps: 2 vCPU, 4 GiB RAM, 12 minutes wall per worker attempt, 5 minutes per verification sandbox.
- **The pass verdict comes only from a fresh verification sandbox** created from the attempt's artifact, which runs
  the frozen checks, the replay fixtures and the held-out check ([ADR 0029](0029-build-verdicts.md)). Inside the
  worker's own sandbox the agent could read the nonce or print a proof line itself, so `run_checks` there is advisory.
- Check shards may run in parallel in separate verification sandboxes that split one verification's 600 vCPU-second
  reservation ([ADR 0030](0030-build-budget-at-egress-proxy.md)); any failing shard is a FAIL (as in PR #45).

## Consequences
- The same-uid leak class does not apply: the worker is the only principal in its VM, the VM holds no secrets, and
  the verdict is taken where the worker never ran.
- Cloud builds send the brief, tokenised fixtures and the user's code context (if any) to E2B. E2B is a sub-processor
  ([SECURITY_PRIVACY.md](../SECURITY_PRIVACY.md#10-sub-processors)). Provider choice is [OQ-08](../OPEN_QUESTIONS.md#oq-08-sandbox-provider-for-cloud-builds).
- Adding a dependency to a build means a new image version, not a registry fetch.
- Setup fixes that edit Claude Code settings (`.claude/`) hit Claude Code's write wall in non-bypass modes (bench
  finding). Those are `setup_change` fixes delivered as a reviewed config patch, not built by a worker.

## Alternatives considered
- Apple Containerization microVM on the user's Mac (old ADR 0013 option B): still on the user's machine. Kept only as a
  dev provider on a dedicated build Mac.
- Hidden user + root helper (old option A): complex, still same machine.
- Registry access through a filtering proxy (the previous version). Rejected: sandboxes hold user data ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P2).
- Managed Agents sandboxes for builds: possible later behind the same port.

## Sources
Old ADR 0013; old `brain/src/builder/{sandbox,supervisor,harness}.ts`; [builder bench report](../SOURCES.md#builder-bench-report); PR #45
(`container.ts`, shards with `--network none`, read-only, cap-drop ALL); apple/container; dagger/container-use; e2b-dev/E2B.

## Revisions
- 2026-11-14: verdict only from a fresh sandbox ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(2)); prebuilt images and no registry access ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P2);
  tokenised fixtures ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P0-3); `apple-container` dev provider and shard rule from PR #45; reaper tag ([design review C (2026-11-14)](../SOURCES.md#design-review-c),
  P1(2)); apple/container attributed ([design review B (2026-11-14)](../SOURCES.md#design-review-b), 11).
- 2026-11-14 (final pass): check shards split one verification's sandbox reservation (final-pass audit of the $4.00 arithmetic).
