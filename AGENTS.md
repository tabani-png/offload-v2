# AGENTS.md

How coding agents (Claude Opus, Sonnet, and others) work in this repo. Read it all before your first change.
Claude-specific notes are in [CLAUDE.md](CLAUDE.md).

## Read order

1. [README.md](README.md): what this is and the repo map.
2. [docs/GLOSSARY.md](docs/GLOSSARY.md): the only vocabulary. Use its words in code, tests, docs and copy.
3. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): the section for the component you touch.
4. [docs/adr/](docs/adr/README.md): the ADRs that section links to.
5. [docs/DATA_MODEL.md](docs/DATA_MODEL.md) and [docs/API.md](docs/API.md): exact tables and shapes.
6. [docs/SECURITY_PRIVACY.md](docs/SECURITY_PRIVACY.md): before touching capture, ingest, models, builds, credentials or commits.
7. Your slice: `slices/<id>/SPEC.md`.
8. [docs/OPEN_QUESTIONS.md](docs/OPEN_QUESTIONS.md): if your slice touches one, build on its recommended default and
   say so in your summary.

## Ground rules

- **Tests first, red first.** Write the slice's red tests, run them, see them fail for the right reason, then write
  code until they pass. Never edit a test to make it pass unless the SPEC was wrong; then fix the SPEC too and note it
  under "Scope changes".
- **Stay in scope.** Change only `paths_in_scope`. A changed file outside `paths_in_scope`, or inside
  `paths_out_of_scope`, fails `verify.sh`. If you must widen
  scope, stop and write a "Scope changes" note in the SPEC explaining why, in the same commit.
- **Numbers come from code** ([ADR 0003](docs/adr/0003-numbers-come-from-code.md)). A model never produces a number
  a user sees or a decision uses.
- **Every external action is gated** ([ADR 0004](docs/adr/0004-every-external-action-is-gated.md)). No code path
  commits without an approval or a policy allow.
- **Masked text only reaches models** ([ADR 0005](docs/adr/0005-masked-text-only-reaches-models.md)). All model calls
  go through the model router.
- **No dry run** anywhere ([ADR 0016](docs/adr/0016-no-dry-run.md)).
- **Deterministic over inference.** If code can decide it, code decides it.
- **No new dependency** without a line in the SPEC's Contract section; a new runtime component (database, queue,
  server) needs an ADR. Pin exact versions.
- **No secrets.** Never read, print or write a secret or an environment variable's value. Only `.env.example` with
  empty values is tracked.
- **Contracts first** ([ADR 0008](docs/adr/0008-contracts-first.md)). Shapes change in `packages/contracts` before
  code uses them.
- **Docs stay true.** If you change behaviour the docs describe, update the docs in the same commit. New terms go in
  the glossary first.

## Slice format

A slice is one vertical, testable change. Folder `slices/<id>/` with `SPEC.md` and `verify.sh`. Copy
`slices/_template/`.

Front-matter keys (all required; `scripts/check-slices.sh` lints them):

| Key | Meaning |
|---|---|
| `id` | Folder name, for example `m3-01-ingest-batches` (milestone, two-digit number, short name) |
| `title` | One line in glossary words |
| `milestone` | `M1` … `M9` from [ROADMAP.md](docs/ROADMAP.md) |
| `status` | `ready`, `in_progress` or `done` (`template` only for `_template`) |
| `depends_on` | Slice ids that must be `done` first (each must be a folder under `slices/`) |
| `parallel_safe` | `true` if it can run at the same time as the other slices in its `parallel_group` (rules below) |
| `human_gated` | `true` if the owner must act (grant permissions, approve a spend, see a demo) |
| `model_tier` | `opus`, `sonnet` or `haiku`: the tier that implements it. Opus always plans and reviews |
| `size` | `S` (under a day), `M` (1 to 2 days) or `L` (3 to 5 days) |
| `parallel_group` | Wave label, for example `M1-A`. Groups run in order (`M1-A` before `M1-B`); slices in one group do not depend on each other |
| `owns` | Shared paths this slice is the only writer of while it runs; `[]` if none |
| `verify` | The command, always `bash slices/<id>/verify.sh` |
| `min_tests` | Minimum number of tests in the slice suite |
| `paths_in_scope` | Globs the slice may change |
| `paths_out_of_scope` | Globs it must not change |
| `red_tests` | Tags; every test name starts with one, for example `test("INGEST: ...")` |

These are the TASKS fields from the old repo's PR #42 (model tier, size, parallel group, shared-file ownership); the
ROADMAP task tables for M2 and later use the same fields.

**Parallel work and shared files.** Two slices run at the same time only if they are in the same `parallel_group` and
both are `parallel_safe: true`. Otherwise they run one after the other. A path that more than one running slice could
touch must be in exactly one of their `owns` lists; the others stay out of it. Root `package.json` and `bun.lock` are
never owned: the second slice to land rebases, runs `bun install`, and commits the regenerated `bun.lock`.

**Test names.** Write `test("TAG: sentence", ...)` with double quotes. `verify.sh` greps for `("TAG: `, so backticks,
single quotes or `it(` are not found and the tag counts as missing. Swift slices use a suite named after the slice
(for example `M302`).

`verify.sh` (Bash 3.2 compatible, `set -uo pipefail`, one `FAIL ...` line per failing check): typecheck; the slice
suite has at least `min_tests` tests and each tag has passing tests (`bun test <dir> -t "TAG: "`); the full suite
passes; every file changed since `BASE` matches `paths_in_scope` and none matches `paths_out_of_scope` (via
`scripts/lib/slice-changes.sh`). `min_tests`, `red_tests` and both path lists are read from the SPEC front-matter;
only `SLICE_ID`, `BASE`, `TEST_DIRS` and `NEEDS_POSTGRES` are edited in `verify.sh`. Set `BASE` to the commit the slice
starts from when you set `status: in_progress`; `scripts/check-slices.sh` fails an `in_progress` or `done` slice with
an empty `BASE`.
In CI the checkout has full history and `SLICE_UPSTREAM` is set (the PR merge commit's first parent, or the previous
`main` tip on push), so only the change's own commits are scope-checked and a slice already `done` there is skipped.
A `done` slice is scope-checked only from `BASE` to the commit that set `status: done` in its SPEC, so later slices
stacked on the same branch are not charged to it; `in_progress` slices still check everything since `BASE`.

`scripts/verify-all.sh` lints every SPEC and `verify.sh`, then runs `verify.sh` for every slice marked `done` with
`SKIP_FULL_SUITE=1` (it already ran the full suite once).

## Definition of done

A slice is done when all of these hold:
1. Every red test in the SPEC exists, was seen failing, and now passes.
2. `bash slices/<id>/verify.sh` prints `<id>: PASS`.
3. `bash scripts/verify-all.sh` is green (typecheck, all tests, license boundary, slices, doc links, copy, secrets).
4. Docs that describe the behaviour are updated; new terms are in the glossary.
5. `NOTICE` lists any third-party code ported in.
6. `status: done` is set in the SPEC in the same commit.
7. A reviewer (below) has passed it.

## Review gate

- Every slice gets a review by an agent that did not write it, reading the SPEC, the diff and the tests, not the
  author's summary. The reviewer checks: tests really fail without the code (spot-check by reverting one function),
  scope, contracts match API.md and DATA_MODEL.md, privacy rules, no numbers from models, gates intact.
- Security-sensitive slices (ingest, auth, masking, approvals, builder, sandbox, runtime gate, vault, audit) also get
  a security review against [SECURITY_PRIVACY.md section 13](docs/SECURITY_PRIVACY.md#13-security-tests-that-must-exist).
- **No merge to `main` without the owner.** Agents work on branches and open changes for review. Nobody pushes to or
  merges into `main` except Muhammad. Never force-push shared branches.

## Commit identity

Every agent, whichever model it runs on, commits as the repo's one bot identity (set in local git config). The model
is not the author; the review gate and the slice id in the message are the record of who did what:

```
git -c user.name="Grok Bot" -c user.email="grok-bot@users.noreply.github.com" commit -m "..."
```

Small logical commits: one slice step per commit (red tests; implementation; docs). Message: `<slice-id>: <what>`.
Never add a git remote or push unless the owner asks.

## License boundary and notices

- Core (`apps/`, `packages/`, `services/`) **never imports** `ee/` or `@offload-ee/*`. `ee/` may import core.
  `scripts/check-license-boundary.sh` enforces it ([ADR 0015](docs/adr/0015-open-core-layout-and-license-gating.md)).
- EE features are plugins registered by `@offload-ee/server-ee` after the license check.
- Third-party code: only from compatible licenses (MIT, Apache-2.0, BSD, ISC). Add the project, URL, license, the
  exact files or functions taken, and the license text where required, to `NOTICE` **in the same commit**. Keep the
  original header in the file.
- **Never copy code** from Elastic License 2.0 (kortix-ai/CompanyOS), SSPL, BSL, AGPL, GPL or commercial sources
  (screenpipe, Quantexa, Cortexa). Ideas only, written fresh.
- gum's screen observer is never used or imported.

## Privacy rules for agents

- Fixtures are synthetic or masked. Never put real names, emails, URLs with paths, or screen text from a real person
  into the repo.
- Never log raw observation text, credentials, approval tokens or message bodies. Log ids and hashes.
- Model prompts in code must go through the router; tests assert the router's masking.

## Model and tool usage

**Standing rule from the owner: all building in this repo is done with Claude Code.**
- Opus 5.5 (`claude-opus-5-5`) for architecture, design, slice planning and review. Claude Fable 5.2
  (`claude-fable-5-2`) is also allowed for architecture and review work.
- Sonnet 5.5 (`claude-sonnet-5-5`) for implementation.
- By default Claude Code is signed into the owner's subscription with `ANTHROPIC_API_KEY` unset. Use an API key only
  where the operator allows it (for example headless parallel workers), and only from the environment the operator set
  up. Never print, log, echo or commit a key, and never check whether one is set by printing it.

These are dev-time choices for agents working on the repo. The product's own model routes are configuration: Opus for
design, check writing and verification, Sonnet for building, Haiku 5.5 (`claude-haiku-5-5`) for classify and caption
([ADR 0021](docs/adr/0021-model-router-and-builders.md)). Fable is never a product route. Do not hard-code model ids
outside config.

- Tests never call a real model or a real third-party service. Use the fakes in `packages/testkit`. Live tests are
  tagged `LIVE:`, skip without credentials, and are never faked.
- Use subagents for independent work. One writer per file at a time.

## Harness commands

```
bun install                         # workspaces
bunx tsc --noEmit -p tsconfig.json  # typecheck everything
bun test                            # all tests
bash scripts/verify-all.sh          # the full harness (CI runs the same)
bash slices/<id>/verify.sh          # one slice
```
