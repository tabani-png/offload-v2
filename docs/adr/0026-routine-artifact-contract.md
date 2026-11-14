# 0026. Routine artifact contract

Status: accepted · Date: 2026-11-14

## Context
Nothing said what a worker builds or what the runtime runs: entry point, language, how code calls a capability, how a
step declares read/draft/commit, how commit items reach a batch, or what stops artifact code doing I/O outside the gate
([design review C (2026-11-14)](../SOURCES.md#design-review-c), P0-2). Opus wrote checks against an undefined interface and "reaches `ready`" was unfalsifiable.

## Decision
- An **artifact** is `routine.json` plus optional **transform modules** plus their tests.
- `routine.json` (schema in `packages/routine-sdk`, JSON Schema 2020-12, `additionalProperties: false`):

  ```
  { v: 1, name,
    trigger: { kind: "schedule" | "webhook" | "event" | "manual", cron?, timezone?, event_type? },
    steps: [ { id, class: "read" | "draft" | "commit" | "transform" | "model",
               runs_on: "cloud" | "device",
               capability?, connection_ref?, args,          // args is a template over earlier step outputs
               foreach?,                                    // iterate over a list from an earlier step
               transform?,                                  // module path for class transform
               model?: { route, prompt_ref, output_schema_ref } } ],
    limits: { max_items_per_run, max_runs_per_day, run_budget_usd, quiet_hours?, recipients_from? },
    capabilities: [ ... ] }
  ```
- **All I/O is done by the runtime** through the connector port and the credential broker. Artifact code never opens a
  socket.
- **Transforms** are pure TypeScript functions (`export default (input) => output`) that import only
  `@offload/routine-sdk/pure`. They run in a no-network isolate with time and memory limits and no host functions
  except the input. Candidate: quickjs-emscripten (MIT), chosen in slice `m1-05-routine-contract` (spike S7).
- **Commit steps return items.** They never call out. The runtime collects items into a batch, hashes them, and the
  gate decides ([ADR 0004](0004-every-external-action-is-gated.md)).
- **`model` steps** (the core of `agent_workflow`) run in an owned Messages-API loop in the runtime
  ([ADR 0021](0021-model-router-and-builders.md)): tool-less, structured output validated against `output_schema_ref`.
  A model that reads untrusted content has no tools (lane separation, PR #42 A§15.1). The Agent SDK is not used at
  run time.
- `runs_on: device` steps go through the device command queue ([ADR 0025](0025-execution-placement-and-mac-actuator.md)).
- **Deploy checks**: `manifest.capabilities ⊆ brief.capabilities`, every `connection_ref` is a connection pinned in the
  brief ([ADR 0033](0033-pinned-connector-resolution-and-launch-catalog.md)), and every transform loads in the isolate.
  The resolved definition is hashed for the deploy approval ([ADR 0032](0032-deploy-approval-binds-definition.md)).
- Checks, replay fixtures and the fake connector in `packages/testkit` all target this SDK. A check runs the routine
  through the SDK's interpreter against the fake connector and asserts the returned items.
- Most routines need no run sandbox at all; only transforms run, in the isolate.

## Consequences
- Workers build a small, declarative artifact plus pure functions, which is easier to verify than free code.
- Some fixes that need arbitrary code at run time do not fit; they become `small_app` (M8) or a device `script` using
  the actuator's typed commands.
- `packages/routine-sdk` is a new core package; its first slice lands in M1, before the first build in M2.

## Alternatives considered
- Free-form scripts in a run sandbox with a connector proxy (the previous version's one sentence). Rejected: every
  routine would need a sandbox and the gate would have to police arbitrary code.
- Agent SDK loops at run time: brings tools the runtime would have to deny; PR #42 A§9.2 chose an owned loop.

## Sources
[Design review C (2026-11-14)](../SOURCES.md#design-review-c), P0-2; PR #42 A§9.2, A§15.1; old `brain/src/workflows/*` (step classes, item journal).
