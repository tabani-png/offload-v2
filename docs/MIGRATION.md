# Migration from the old repo

What v2 harvests from the old Offload repo (`/workspace/offload`, branch `main` at `1df915d`, plus local branches) and
from the other inputs. Fates: **keep** (port the code, behaviour unchanged), **rewrite** (keep the idea and the
tests' intent, new code), **drop**. Paths on the left are old; on the right, new. Words follow
[GLOSSARY.md](GLOSSARY.md).

Old code is "all rights reserved" by its owner. Porting it under the v2 license waits on
[OQ-12](OPEN_QUESTIONS.md#oq-12-relicensing-code-from-the-old-repo); the default is yes.

## Inputs read

| Input | Used for |
|---|---|
| Old repo `main` and branches (below) | everything in sections 2 to 4 |
| `/workspace/offload-app/spec.md` (M0 to M9 spec, memory design, ranking formula, Clicky teardown, Mem0/Cognee vs gum+graphiti, recap UI refs) | [ARCHITECTURE sections 5 and 6](ARCHITECTURE.md#5-cloud-brain-and-user-model), [ROADMAP](ROADMAP.md), [ADR 0019](adr/0019-user-model-storage.md) |
| `/workspace/repo-scout/log.md` (scouted repos, licenses, fit scores) | sandbox, connector and memory choices; [NOTICE](../NOTICE) |
| Research Page "approve → build → ship" | build pipeline, verifier, receipts, layered user model |
| Mockups Page (onboarding, Today, Weekly review, Build progress) | [PRODUCT.md section 4](PRODUCT.md#4-screens) |
| `/workspace/offload-bench/README.md` | [ADR 0012](adr/0012-builder-policy-one-worker-held-out-fan-out.md) |
| `/workspace/offload-pricing/LEARNINGS.md` | [PRODUCT.md copy rules](PRODUCT.md#copy-rules) and UI direction |

## 2. Old repo parts

### Engine (Swift observer) → `apps/mac`

| Old path | Fate | New path | Why |
|---|---|---|---|
| `engine/Sources/OffloadCore/Capture/{CaptureTypes,ExclusionPolicy,UserExclusions,PerceptualHash,TextRecognizer,URLScrubber,WindowPlan}.swift` | keep | `apps/mac/Sources/OffloadObserver/` | Proven capture; 183 tests in the old engine |
| `engine/Sources/OffloadCore/Detectors/*` | keep | `apps/mac/Sources/OffloadMasker/` | On-device masking ([ADR 0005](adr/0005-masked-text-only-reaches-models.md)) |
| `engine/Sources/OffloadCore/Capture/Keyframe.swift` | keep | `apps/mac/Sources/OffloadObserver/` | Throttle and renderer; stays local unless opt-in |
| `engine/Sources/OffloadCore/Observer/*` (state machine, OCR executor) | keep | `apps/mac/Sources/OffloadObserver/` | Cadence constants unchanged |
| `engine/Sources/OffloadCore/Store/{DayStore,FrameStore,KeyVault,StoreCrypto,StoreLayout,Retention}.swift` | keep | `apps/mac/Sources/OffloadStore/` | AES-256-GCM day files, Keychain master key |
| `engine/Sources/OffloadCore/Store/BrainKeys.swift` | drop | | No local brain |
| `engine/Sources/offload-observer/` CLI + LaunchAgent | rewrite | `apps/mac/Sources/OffloadMac/` | Capture runs inside the app process; CLI only for debug |
| `engine/build.sh` (plain swiftc) | drop | `apps/mac/Package.swift` | SwiftPM ([ADR 0024](adr/0024-client-stacks.md)) |
| `engine/Tests/S02/S02StoreTests.swift` `S02NoNetworkTests` | keep | `apps/mac/Tests/OffloadMacTests/M105/` | NONET test |
| `wip/s34-mac` `engine/.../VideoFrames.swift` (`extract-frames`) | keep | `apps/mac/Sources/OffloadImport/` | Recordings import |

### App (SwiftUI) → `apps/mac`

| Old path | Fate | New path | Why |
|---|---|---|---|
| `app/Sources/Core/{Onboarding,UserContext}.swift` | rewrite | `apps/mac/Sources/OffloadMac/Onboarding/` | New 10-step flow from the mockups |
| `app/Sources/Core/{BrainClient,HTTPBrainClient,BrainSupervisor}.swift` | drop | | No local brain; app talks to the cloud API |
| `app/Sources/Core/Approval.swift`, `Surfaces/ReviewView*.swift` | rewrite | `apps/mac/Sources/OffloadMac/Approvals/` | Batch approval card with exact hash; no dry-run panel |
| `app/Sources/Core/Pointer.swift`, `Design/PointerOverlay.swift` | keep | `apps/mac/Sources/OffloadMac/Design/` | In-window pointer, clean-room Clicky arc |
| `app/Sources/Design/{Theme,Motion,Components}.swift`, `Core/Tokens.swift` | rewrite | generated tokens from `packages/contracts` | One token source for Mac and web |
| `app/Sources/Surfaces/{RailView,InsightCardView,DashboardView,TimeView}.swift` | rewrite | Today, Weekly review, Build progress, Routines | New screens |
| `app/Sources/Surfaces/Company/*` (S2-13) | drop | web app | Team surfaces move to the web app |
| `app/build.sh`, `app/release.sh`, s25/s28 bundling | rewrite | CI `mac` job + release workflow (M8) | No brain bundle; notarized DMG |
| `app/brain.entitlements` | drop | | No embedded bun |

### Brain (Bun + TS) → `services/*`, `packages/*`

| Old path | Fate | New path | Why |
|---|---|---|---|
| `brain/src/sessionize.ts` | keep | `services/brain/src/understanding/sessionize.ts` | Constants: 10 s min span, 15 min idle merge, 120 s backdate |
| `brain/src/understanding/{induce,embed,describe,surfaces,verbs,labeler}.ts` | keep | `services/brain/src/understanding/` | Deterministic induction with golden tests (50) |
| `brain/src/understanding/pipeline.ts`, `analyze.ts` | rewrite | `services/brain/src/understanding/pipeline.ts` | New store and event wiring |
| `brain/src/grouping/*` | rewrite | fallback features inside understanding | Email-centric bundle sets |
| `brain/src/stats.ts`, `insights/{rank,saving}.ts` | keep | `services/brain/src/opportunities/` | Code-only figures |
| `brain/src/insights/judge.ts` | rewrite | `services/brain/src/opportunities/judge.ts` | Was a heuristic stub |
| `brain/src/solutions/{rules,signals,types,brief,left-alone}.ts` | keep | `services/brain/src/fixes/` | Five-kind rules become the new fix kinds (mapping below) |
| `brain/src/solutions/design.ts` | keep | `services/brain/src/fixes/design.ts` | Opus wording pass only |
| `brain/src/builder/{checks,approval,record}.ts` | rewrite | `services/builder/src/` | Keep concepts: frozen check + sha, exact-hash single-use approval (add TTL, one scheme), append-only records, artifact hash |
| `brain/src/builder/{harness,supervisor}.ts` | keep (protocol) | `services/builder/src/harness/` | Nonce proof and sweep run inside the sandbox |
| `brain/src/builder/{sandbox,runner}.ts` | rewrite | `services/builder/src/sandbox/`, `src/worker/` | `sandbox-exec` replaced by the SandboxProvider port ([ADR 0011](adr/0011-sandboxed-build-workers.md)) |
| `brain/src/connectors/{chain,targets,capabilities,secrets}.ts` | keep | `packages/connectors-sdk/src/` | Chain order and capability vocabulary |
| `brain/src/connectors/{mcp-client,composio,api}.ts` | rewrite | `packages/connectors-sdk/src/adapters/` | Cloud vault instead of Keychain references |
| `brain/src/connectors/link.ts` (demo simulation), legacy `via` | drop | | Stub code |
| `brain/src/connectors/computer/*` | rewrite | `packages/connectors-sdk/src/adapters/browser/` | Runs in a sandbox, not via AppleScript on the Mac |
| `brain/src/workflows/{gate,allowlist,denied,untrusted,generic}.ts` | keep | `services/runtime/src/gate/` | Core of the safety story; gate mode `dry_run` removed |
| `brain/src/workflows/batch.ts` | rewrite | `services/runtime/src/batch.ts` | JCS instead of `JSON.stringify`; hashed tokens with TTL |
| `brain/src/workflows/{runner,executor,chain-executor,store,autorun,schedule}.ts` | rewrite | `services/runtime/src/` | Durable runtime, routines, triggers |
| `brain/src/workflows/{drafter,dryrun}.ts`, `plan/dryrun.ts` | drop | | No dry run ([ADR 0016](adr/0016-no-dry-run.md)); drafting moves into fix design and routine draft steps |
| `brain/src/plan/{steps,capabilities,commit-fields,probe}.ts` | keep | `services/brain/src/fixes/plan/` | Typed read/draft/commit plans |
| `brain/src/plan/read-source.ts` (1078 lines) | rewrite | `services/runtime/src/reads/` | Too large; keep the rules from old ADR 0015 |
| `brain/src/privacy/{names,lexicon,policy}.ts` | keep | `packages/masking/src/` | Name masker, 82 tests |
| `brain/src/playbook/{types,leak,mask,stats}.ts` | keep | `services/brain/src/playbook/` | Messaging playbook; wordlist loaded as data, not TS |
| `brain/src/tone/{bm25,clean,style}.ts` | keep | `services/brain/src/tone/` | Tone in drafts |
| `brain/src/tone/bucket.ts` | rewrite | | Email-only buckets |
| `brain/src/models/router.ts` | keep | `services/brain/src/models/router.ts` | Model ids and prices move to config |
| `brain/src/store/{vault,crypto,retention,reader}.ts` | drop | | Mac store is Swift; cloud store is Postgres |
| `brain/src/time/{breakdown,kinds}.ts` | keep | `services/brain/src/records/` | Work kinds: code, docs, meeting, sheet, email, chat, browse, other |
| `brain/src/sync/*` (stage-2 company sync) | rewrite | `apps/mac` uploader + `services/api` ingest | New protocol ([ADR 0020](adr/0020-device-ingest-protocol.md)); one JCS implementation |
| `brain/src/api/*` (per-slice route files) | rewrite | `packages/contracts` + `services/api` | One versioned contract |
| `brain/src/vision/*` | rewrite | `services/brain/src/vision/` | Only for opt-in keyframes; Haiku `caption` route |
| `brain/src/context/store.ts` | rewrite | `profiles` table | Profile API |
| `brain/fixtures/*` | keep | `packages/testkit/fixtures/` | Synthetic data |
| `brain/tools/import-screenwatch.ts` | keep | see `wip/s34-brain` | Import path |

Fix kind mapping: old `workflow` → `agent_workflow`; old `tool` → `script`, `small_app` or `api_integration`; old
`setup` → `setup_change`; old `remove_step` → `remove_step` (now a non-build outcome); old `leave_alone` →
`leave_alone`. New: `scheduled_routine`, `browser_automation`.

### Control plane, packages, schemas, web, compliance, harness

| Old path | Fate | New path | Why |
|---|---|---|---|
| `packages/hours-saved` | keep (as is) | `packages/hours-saved` | hs-1, 98 tests, golden fixtures ([ADR 0022](adr/0022-hours-saved-hs-1.md)) |
| `control/src/db/*` (`withTenant`, migration runner) | keep | `packages/db/src/` | RLS pattern |
| `control/migrations/0100..0102` (core tables, RLS roles) | rewrite | `packages/db/migrations/` | New table set ([DATA_MODEL.md](DATA_MODEL.md)) |
| `control/src/audit/{audit,anchor,verify-chain}.ts` | keep | `packages/db/src/audit/` | Hash chain, anchors, verify |
| `control/src/auth/*` | rewrite | `services/api/src/auth/` | OIDC in core, WorkOS as a config ([ADR 0014](adr/0014-identity.md)) |
| `control/src/rbac/permissions.ts` | rewrite | `packages/policy` (Cedar) | Roles change; matrix becomes built-in policies |
| `control/src/modules/registry/*` | rewrite | routines and versions | Immutable versions, `definition_hash` kept |
| `control/src/modules/policies/*`, `broker/*` | rewrite | `services/runtime`, `packages/policy` | Overnight policy becomes graduation + quiet hours + breakers |
| `control/src/modules/workers/*` (Managed Agents) | drop for now | | Routines run in the runtime; Managed Agents stays a possible sandbox provider |
| `control/src/modules/continuity/*` | rewrite later | M9 | Offboarding for Enterprise |
| `control/src/modules/compliance/*`, `compliance/templates/*` | keep | M8/M9 | Monitoring-law records and notice templates |
| `control/src/modules/metrics/*` (floor, suppression) | keep | `services/runtime/src/metrics/` | Group floor of 5 |
| `control/src/app.ts` module loader, `ports.ts` | rewrite | plugin registry ([ADR 0015](adr/0015-open-core-layout-and-license-gating.md)) | Core/EE seam |
| `schemas/*.schema.json`, `schemas/stage2/*` | rewrite | `packages/contracts` | zod source of truth |
| `web/` (S2-04 admin SPA) | rewrite | `apps/web` | New screens; keep tokens and CSP approach |
| `compliance/{data-map,dpa-subprocessors}.md` | rewrite | [SECURITY_PRIVACY.md](SECURITY_PRIVACY.md) | New data flows |
| `AGENTS.md`, `CLAUDE.md`, `docs/adam-rules.md`, `docs/adam-folder-contract.md` | rewrite | [AGENTS.md](../AGENTS.md), [CLAUDE.md](../CLAUDE.md) | Same rules, one place |
| `adam.json` (`tests_first_strict`, `max_parallel_builders: 4`, `auto_merge_to_main: false`) | rewrite | AGENTS.md | Same intent; no separate config file |
| `agent-control/*` | drop | | Mostly unfilled templates; state lives in slices and git |
| `slices/<id>/{SPEC.md,verify.sh}` format | keep | `slices/_template/` | Same front-matter keys plus `milestone`, `status`, `min_tests`, `red_tests` |
| `scripts/lib/slice-changes.sh` | keep (simplified) | `scripts/lib/slice-changes.sh` | Scope checks |
| `scripts/verify-all.sh` | rewrite | `scripts/verify-all.sh` | Workspace-wide harness |

### Old ADRs → v2 ADRs

| Old ADR | v2 |
|---|---|
| 0001 new repo reuse Workpaper | context only; [0001](adr/0001-record-decisions-and-v2-scope.md) |
| 0002 plain swiftc | superseded by [0024](adr/0024-client-stacks.md) |
| 0003 metadata-first privacy | [0006](adr/0006-metadata-first-capture.md) |
| 0004 Agent SDK execution | [0010](adr/0010-mcp-first-connectors.md), [0021](adr/0021-model-router-and-builders.md) |
| 0005 deterministic numbers | [0003](adr/0003-numbers-come-from-code.md) |
| 0006 approval gates | [0004](adr/0004-every-external-action-is-gated.md) |
| 0007 perception any domain | [0005](adr/0005-masked-text-only-reaches-models.md), [0006](adr/0006-metadata-first-capture.md) |
| 0008 Anthropic SDK computer use | [0010](adr/0010-mcp-first-connectors.md) (browser adapter) |
| 0009 model router | [0021](adr/0021-model-router-and-builders.md) |
| 0010 name masking | [0005](adr/0005-masked-text-only-reaches-models.md) |
| 0011, 0012 messaging playbook | kept as code; no new ADR needed |
| 0013 safe builder (proposed) | superseded by [0011](adr/0011-sandboxed-build-workers.md) |
| 0014 standalone brain bundle | dropped ([0007](adr/0007-cloud-brain-thin-mac-client.md)) |
| 0015 read steps | rules kept in runtime reads; [0004](adr/0004-every-external-action-is-gated.md) |
| 0101 multi-tenant RLS | [0013](adr/0013-tenancy-and-rls.md) |
| 0102 identity RBAC | [0014](adr/0014-identity.md) |
| 0103 sync protocol | [0020](adr/0020-device-ingest-protocol.md) |
| 0104 workflow registry | routines and versions in [DATA_MODEL.md](DATA_MODEL.md#7-routines-and-runs) |
| 0105 cloud workers on Managed Agents | dropped for v2 runtime; possible sandbox provider |
| 0106 overnight policy | [0016](adr/0016-no-dry-run.md) (graduation), [0017](adr/0017-policy-engine-cedar.md) (quiet hours, breakers) |
| 0107, 0113 continuity | M9 |
| 0108 monitoring compliance | [SECURITY_PRIVACY.md section 12](SECURITY_PRIVACY.md#12-compliance-notes-not-legal-advice), [0018](adr/0018-audit-log-hash-chain.md) |
| 0109 hours saved hs-1 | [0022](adr/0022-hours-saved-hs-1.md) |
| 0110 control-plane stack | [0002](adr/0002-stack-bun-typescript-hono-postgres.md) |
| 0111 to 0114 amendments | folded into the ADRs above where still relevant |

## 3. Things deliberately changed

- **Dry run removed** everywhere: gate mode, workflow lifecycle, copy, `dryRunNights` ([ADR 0016](adr/0016-no-dry-run.md)).
  The s34 rename to "Preview from your last week" is not carried over either; replay happens inside the build.
- **One approval scheme** (hashed token, single use, 24 h TTL) replaces the build token and the plain-text workflow token.
- **One canonicaliser** (JCS) replaces three.
- **Brain to the cloud**; the Mac bundle no longer ships bun or the brain.
- **Run outcomes and baselines** are computed in the cloud, so the old sync kinds `run_outcome`, `baseline_sample`,
  `daily_aggregate`, `working_time_aggregate`, `workflow_proposal` are gone.

## 4. In-flight branches

Read with `git -C /workspace/offload log/diff main..<branch>`. None is merged; ports follow the slices.

| Branch | What is there | Port | Drop |
|---|---|---|---|
| `release/mac-testable` (M0) | s33 UI audit commits; pinned bun fetch with SHA-256 check in `app/build.sh`; `INSTALL_AND_TEST.md`; "no dry-run ceremony" copy (`c85ef44`) | Install-and-test doc structure, rewritten for a release workflow that exists (the referenced `mac-release.yml` is in no ref); the checksum-verified download pattern for any pinned tool | Pinned bun bundling (no brain on the Mac); the "Preview from your last week" wording |
| `feat/capture-from-clicky` (s34 tests only, no implementation) | Red tests for `GET /now` (NOW-1..8: top 3 apps, switches inside the window, idle excluded, exact line, zero model calls); "Never watch" → observer exclusions; Clicky permission rules (1.5 s polling, grant survives a false negative preflight) | `/now` as the Mac-local "last 10 minutes" summary with its tests as acceptance criteria (M2); Never watch; permission polling; filename-timestamp rules and the stable-file gate (size unchanged 3 s) into the import path | Engine-side `ingest-folder` design (superseded by the built brain-side import) |
| `feat/user-model-gum-graphiti` (s36, 55 tests) | Profile API (goals ≤ 3, drains, schedule, review slot, autonomy, exclusions); sealed memory; day records and episodes; task ledger (`k_` keys, signature → kind/app/host + Jaccard ≥ 0.5 → new key); gum-style propositions (rule confidence, decay, versions, 50% contradiction rule, 7-day stale rule); graphiti-style bi-temporal edges; week/month/quarter rollups with Theil-Sen; goal-weighted opportunity score; `checkNarrative`; review API | Most valuable branch. Port as code: ledger, day/week records, Theil-Sen, opportunity formula, `checkNarrative`, proposition rules. Port as concept: propositions and edges as Postgres tables ([ADR 0019](adr/0019-user-model-storage.md)). Add centroid cosine matching (missing). | Sealed local files (now Postgres); `sequence` and `precedes` until M7; drift/realized stubs (re-specified in M6/M7) |
| `feat/build-loop` (1 commit, 50 tests) | `okBuild`: held-out check (optionally local model), one builder with TDD append, teeth gate, container check shards (`--network none --read-only --cap-drop ALL`), fan-out up to 3 after FAIL, budget $4 with $0.30 checks reserve, outcomes (`on_track` ≥ 80%, `partial` ≥ 50%) | Concepts into [ADR 0012](adr/0012-builder-policy-one-worker-held-out-fan-out.md); `outcomes.ts` measured-vs-estimated idea into M6; container flags into the Docker provider | apple/container runner on the Mac; `sandbox-exec` fallback |
| `wip/s34-brain` (28 tests) | `import-folder` CLI: screenwatch archives, screenshots, videos via `extract-frames`; JSONL progress protocol; masked text only; no frames kept; captions cached; `--max-usd`; import home exempt from purge, anchored to its last day | Import as an import space (`imports` table, `source = 'import'`); JSONL progress lines for the Mac panel; cost cap | Local import home and brain restart |
| `wip/s34-mac` (14 Swift tests) | `extract-frames` (AVAssetImageGenerator, 1280 px, JPEG 0.6); "Choose recordings folder…" UI; progress panel adapted from farzaa/clicky `MenuBarPanelManager.swift` (MIT) with a root `NOTICE`; source pill, "Switch to live", "Remove imported data" | `extract-frames`, the panel (with its MIT notice into v2 `NOTICE`), the import copy | Brain relaunch with `--home` |
| `ui/mac-audit-fixes` (s33, 28 Swift tests written on Linux, never compiled) | Buddy moods, connection grouping (Connected / Needs you / Ready to set up), one-sentence time headline, maths behind a link, lime highlight token for time saved, Simple Icons logos (old ADR 0016 proposed) | Concepts and Core logic, re-verified on a Mac | Logos until [OQ-20](OPEN_QUESTIONS.md#oq-20-brand-logos-in-the-app) |
| `feat/recordings-import` | Integration of `wip/s34-brain` + `wip/s34-mac` + M0 | Use as the reading reference for the import port | |
| `docs/architecture-plan`, `ui/audit-first-fixes` | Already in `main` | nothing | |

Known gaps found while reading: two root `NOTICE` files on different branches (`wip/s34-mac`, `feat/build-loop`) must
be merged into one; `brain/src/usermodel/NOTICE.md` is referenced but missing (gum is MIT, graphiti Apache-2.0).
v2 `NOTICE` lists ideas-only sources and requires a notice in the same commit as any ported code.
