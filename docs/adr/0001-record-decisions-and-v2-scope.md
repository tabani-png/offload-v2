# 0001. Fresh v2 repo, harvest the old one, record decisions here

Status: accepted, revised 2026-11-14 · Date: 2026-11-14

## Context
The old repo (`tabani-png/offload`, local at `/workspace/offload`) is a working local-first prototype: a Swift observer,
a Bun brain on 127.0.0.1, a SwiftUI app, and a stage-2 control plane. It grew slice by slice. It has duplicate ADR
numbers (three 0112s, three 0113s), stub ADRs (0001 to 0006 are two lines each), per-slice route files, three JSON
canonicalisers and two approval token schemes. v2 moves the brain to the cloud ([ADR 0007](0007-cloud-brain-thin-mac-client.md)),
which changes most seams. Five pull requests (#41 to #45) were still open on the old repo when v2 was revised; PR #42
is an earlier plan of record whose privacy controls v2 now reconciles ([ADR 0035](0035-mac-egress-guard-and-ledger.md)).

## Decision
- Start a new monorepo, `offload-v2`. Copy no git history. Harvest code and ideas through [MIGRATION.md](../MIGRATION.md),
  which marks each part kept, rewritten or dropped.
- Record every architecture decision here, one per file. The editing rule (in place until the first feature slice is
  `done`, append-only after) is in [the ADR index](README.md).
- Owner-only decisions go to [OPEN_QUESTIONS.md](../OPEN_QUESTIONS.md) with a recommended default. Agents build on the
  default and the question stays marked until the owner answers.
- One glossary ([GLOSSARY.md](../GLOSSARY.md)) governs names.

## Consequences
- The old repo stays read-only input. Its in-flight branches are ported by plan, not merged.
- Old code is "all rights reserved". Relicensing it under the v2 license is the owner's call ([OQ-12](../OPEN_QUESTIONS.md#oq-12-relicensing-code-from-the-old-repo)).
  The first port (the audit chain writer in slice m1-03-tenancy-rls) waits on it.

## Alternatives considered
- Continue in the old repo. Rejected: the move to a cloud brain touches nearly every module and the slice history makes
  the layout hard for new agents to follow.

## Sources
Old `plan/plan.md`, old ADRs 0001 to 0015 and 0101 to 0114, `docs/adam-rules.md`; PR summaries #41 to #45.

## Revisions
- 2026-11-14: in-place editing rule moved to the ADR index; first port named (review-b 8); PRs #41 to #45 named as inputs.
