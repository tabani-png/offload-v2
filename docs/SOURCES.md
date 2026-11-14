# Sources

The named sources the docs and ADRs cite. Public sources have a link. Internal notes are the owner's working
material: they are **internal, not published**, and this repo states what it took from each, so nothing here depends
on reading them. Words follow [GLOSSARY.md](GLOSSARY.md).

## Public sources

### Old repo

[`tabani-png/offload`](https://github.com/tabani-png/offload): the local-first prototype v2 harvests, at `main`
`1df915d`. Old paths written as `old brain/src/...`, "old ADR NNNN" and old `plan/...` files are in this repo.
What is kept, rewritten or dropped is in [MIGRATION.md](MIGRATION.md).

### Old repo pull requests

"PR #N" means `https://github.com/tabani-png/offload/pull/N`. The PR summaries #41 to #45 cited as inputs are these
PRs' descriptions and diffs. Section markers such as "PR #42 A§9.5" or "ONB§6" point into the plan documents of
PR #42 (A = architecture plan, ONB = onboarding).

| PR | Branch and content |
|---|---|
| [#40](https://github.com/tabani-png/offload/pull/40) | `ui/audit-first-fixes`, merged into `main` |
| [#41](https://github.com/tabani-png/offload/pull/41) | `release/mac-testable`, M0 installable build |
| [#42](https://github.com/tabani-png/offload/pull/42) | `docs/architecture-plan`, the earlier plan of record (7 plan docs) |
| [#43](https://github.com/tabani-png/offload/pull/43) | `feat/user-model-gum-graphiti`, s36 user memory |
| [#44](https://github.com/tabani-png/offload/pull/44) | `feat/capture-from-clicky`, s34 recordings ingest |
| [#45](https://github.com/tabani-png/offload/pull/45) | `feat/build-loop`, s35 OK, build |

### Old repo branches

A branch `<name>` (or `origin/<name>`) is `https://github.com/tabani-png/offload/tree/<name>`. The ones the docs name:

- [`main`](https://github.com/tabani-png/offload/tree/main)
- [`release/mac-testable`](https://github.com/tabani-png/offload/tree/release/mac-testable)
- [`ci/mac-release-workflow`](https://github.com/tabani-png/offload/tree/ci/mac-release-workflow) (local only when read; the link resolves once pushed)
- [`docs/architecture-plan`](https://github.com/tabani-png/offload/tree/docs/architecture-plan)
- [`feat/user-model-gum-graphiti`](https://github.com/tabani-png/offload/tree/feat/user-model-gum-graphiti)
- [`feat/capture-from-clicky`](https://github.com/tabani-png/offload/tree/feat/capture-from-clicky)
- [`feat/build-loop`](https://github.com/tabani-png/offload/tree/feat/build-loop)
- [`backup/build-loop-pre-move`](https://github.com/tabani-png/offload/tree/backup/build-loop-pre-move) (local only when read; the link resolves once pushed)
- [`wip/s34-brain`](https://github.com/tabani-png/offload/tree/wip/s34-brain) (local only when read; the link resolves once pushed)
- [`wip/s34-mac`](https://github.com/tabani-png/offload/tree/wip/s34-mac) (local only when read; the link resolves once pushed)
- [`feat/recordings-import`](https://github.com/tabani-png/offload/tree/feat/recordings-import) (local only when read; the link resolves once pushed)
- [`ui/mac-audit-fixes`](https://github.com/tabani-png/offload/tree/ui/mac-audit-fixes)
- [`s32-retention-30d`](https://github.com/tabani-png/offload/tree/s32-retention-30d)
- [`research/cindy-eval`](https://github.com/tabani-png/offload/tree/research/cindy-eval)
- [`design-review-4`](https://github.com/tabani-png/offload/tree/design-review-4)
- [`docs/readme`](https://github.com/tabani-png/offload/tree/docs/readme)
- [`handoff-2026-10-25`](https://github.com/tabani-png/offload/tree/handoff-2026-10-25)
- [`ui/audit-first-fixes`](https://github.com/tabani-png/offload/tree/ui/audit-first-fixes)

The other `origin/*` branches listed in [MIGRATION section 4.2](MIGRATION.md#42-every-branch) follow the same
pattern; all of them are merged into `main` or context only.

### Third-party repositories

Licenses as read on 2026-11-14; what v2 plans to take from each is in [NOTICE](../NOTICE).

- [farzaa/clicky](https://github.com/farzaa/clicky) (MIT)
- [GeneralUserModels/gum](https://github.com/GeneralUserModels/gum) (MIT)
- [getzep/graphiti](https://github.com/getzep/graphiti) (Apache-2.0)
- [obra/superpowers](https://github.com/obra/superpowers) (MIT)
- [garrytan/gstack](https://github.com/garrytan/gstack) (MIT)
- [dagger/container-use](https://github.com/dagger/container-use) (Apache-2.0)
- [storytold/craft-anything](https://github.com/storytold/craft-anything)
- [nizos/tdd-guard](https://github.com/nizos/tdd-guard) (MIT)
- [apple/container](https://github.com/apple/container) (Apache-2.0)
- [exo-explore/exo](https://github.com/exo-explore/exo) (Apache-2.0)
- [dbos-inc/dbos-transact-ts](https://github.com/dbos-inc/dbos-transact-ts) (MIT)
- [cedar-policy/cedar](https://github.com/cedar-policy/cedar) (Apache-2.0)

## Internal notes (not published)

### Owner brief

Internal, not published. The owner's brief for v2: cloud brain with a thin Mac client, self-host with only Postgres, no dry run, and the scope the ADRs start from.

### Product spec (M0 to M9)

Internal, not published. The milestone spec M0 to M9: onboarding questions, user-model memory design, the ranking formula, the Clicky teardown, Mem0/Cognee against gum and graphiti, recap UI references, and the hours-saved definition (§4.4).

### Repo scout log

Internal, not published. Scouted open-source repositories with licenses and fit scores; used for sandbox, connector, memory and policy choices and for [NOTICE](../NOTICE).

### Builder bench report

Internal, not published. The 2026-11-14 bench of build workers (6 briefs, 42 builds): one Sonnet worker against best-of-4 and mutation-score picking, per-build costs, and the `.claude/` write wall noted in [CLAUDE.md](../CLAUDE.md); basis of [ADR 0012](adr/0012-builder-policy-one-worker-held-out-fan-out.md).

### Pricing LEARNINGS

Internal, not published. Learnings from the pricing page work; source of the copy and motion rules in [PRODUCT.md](PRODUCT.md#copy-rules) and [ONBOARDING.md](ONBOARDING.md).

### Research Page

Internal, not published. Research on "approve → build → ship": build pipeline, verifier, receipts, a rule id on every policy decision, and the layered user model.

### Mockups Page

Internal, not published. The approved mockups (onboarding in 10 steps, Today, Weekly review, Build progress); source of the screen order and copy in [PRODUCT.md section 4](PRODUCT.md#4-screens) and [ONBOARDING.md](ONBOARDING.md).

### Design review A

Design review A (2026-11-14), internal, not published: a line-by-line consistency review with numbered findings (#1 to #119) on contracts, identity, ingest, tenancy, audit chain and API shapes. Cited as "design review A (2026-11-14), #N".

### Design review B

Design review B (2026-11-14), internal, not published: a review of facts, attributions and open-core fit with numbered items (and P0-5 on where browser fixes run). Cited as "design review B (2026-11-14), N".

### Design review C

Design review C (2026-11-14), internal, not published: the architecture review with P0, P1 and P2 findings (execution placement, routine contract, fixture capture, pseudonyms, service layout, verdicts, connectors, identity, Mac egress, signing). Cited as "design review C (2026-11-14), P1(2)" and similar.
