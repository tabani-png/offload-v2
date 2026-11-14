# CLAUDE.md

Start with [AGENTS.md](AGENTS.md). Everything there applies. These are Claude-specific notes.

## Before you write code

- Read the files in AGENTS.md's read order. Use the glossary's words exactly.
- Load the superpowers skills when available: `test-driven-development` (red, green, refactor),
  `verification-before-completion` (run `verify.sh` and paste the result before saying done),
  `subagent-driven-development` for multi-part slices.
- Opus plans and reviews; Sonnet implements. A subagent gets the SPEC path, the doc sections and the exact test tags,
  not a summary of your conclusions.

## While you work

- No source edit before a failing test exists for it (the same rule the build workers' tdd-guard hook enforces).
- Run `bash slices/<id>/verify.sh` before claiming a slice is done. Show its output.
- Keep edits inside `paths_in_scope`.

## The `.claude/` write wall

Claude Code refuses writes under `.claude/` in `dontAsk` and `acceptEdits` modes, even with explicit allow rules
(found in the 2026-11-14 bench). So:
- Do not plan slices that need an agent to write `.claude/` settings unattended.
- Product fixes that change a user's Claude Code settings are `setup_change` fixes delivered as a reviewed config
  patch, never built by a worker ([ADR 0011](docs/adr/0011-sandboxed-build-workers.md)).
- If this repo ever needs `.claude/` files, the owner adds them by hand.

## Things not to do

- Do not create remotes, push, open PRs on GitHub, or merge into `main`.
- Do not read or print environment variable values or secrets.
- Do not call real models or services from tests.
- Do not write "dry run" in product code, APIs or copy.
