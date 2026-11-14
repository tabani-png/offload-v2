# CLAUDE.md

Start with [AGENTS.md](AGENTS.md). Everything there applies. These are Claude-specific notes.

## Before you write code

- Read the files in AGENTS.md's read order. Use the glossary's words exactly.
- Load the superpowers skills when available: `test-driven-development` (red, green, refactor),
  `verification-before-completion` (run `verify.sh` and paste the result before saying done),
  `subagent-driven-development` for multi-part slices.
- All building in this repo is done with Claude Code (the owner's standing rule,
  [AGENTS.md](AGENTS.md#model-and-tool-usage)). Opus 5.5 (`claude-opus-5-5`) plans, designs and reviews; Claude Fable
  5.2 (`claude-fable-5-2`) may also do architecture and review work; Sonnet 5.5 (`claude-sonnet-5-5`) implements. Set a
  subagent's model to match the slice's `model_tier`. A subagent gets the SPEC path, the doc sections and the exact
  test tags, not a summary of your conclusions.
- Claude Code runs signed into the owner's subscription by default, with `ANTHROPIC_API_KEY` unset. Use the API key
  only where the operator allows it (headless parallel workers). Never print, echo or log a key or any environment
  variable value, including to check that it is set.
- Commits use the repo's bot identity from [AGENTS.md](AGENTS.md#commit-identity), whichever model wrote the code.

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
