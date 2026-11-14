---
id: _template
title: One line. What the slice delivers, in the glossary's words.
milestone: M1
status: template
depends_on: []
parallel_safe: true
human_gated: false
model_tier: sonnet
size: M
parallel_group: M1-A
owns: []
verify: bash slices/_template/verify.sh
min_tests: 1
paths_in_scope: [packages/example/**, slices/_template/**]
paths_out_of_scope: [ee/**, apps/mac/**, docs/adr/**]
red_tests: [EXAMPLE]
---

# _template

Copy this folder to `slices/<id>/`, set `id` to the folder name and `status: ready`.
Field meanings are in [AGENTS.md](../../AGENTS.md#slice-format).

## Summary
Two or three sentences. Which milestone exit criterion this moves. Link the doc sections it implements.

## Contract
First line, when the slice is the first to touch a package: "Delete `<pkg>/tests/smoke.test.ts` (the TODO marker is
replaced)". Name every new dependency with an exact pin. Exact types, endpoints, tables or schemas this slice adds or changes. Copy them from
[API.md](../../docs/API.md) and [DATA_MODEL.md](../../docs/DATA_MODEL.md). If the docs are wrong, fix the docs
in this slice and say so under "Scope changes".

## Red tests (write these first, run them, see them fail)
Tests live in `<package>/tests/<slice-id>/`. Each test name starts with its tag, for example
`test("EXAMPLE: rejects an empty batch", ...)` (double quotes; verify.sh greps for `("TAG: `).
Swift slices put every test in `@Suite struct M<milestone><nn>` (for example `M302`) under
`apps/mac/Tests/OffloadMacTests/M<milestone><nn>/` instead.

| Tag | Test name | Asserts |
|---|---|---|
| EXAMPLE | EXAMPLE: does the thing | the exact observable result |

## Out of scope
What this slice must not do, even if it looks related.

## Verify
`bash slices/<id>/verify.sh`: typecheck; the slice suite has at least `min_tests` tests and every tag is present
and passing; the full suite passes; every change since `BASE` matches `paths_in_scope` and none matches
`paths_out_of_scope`. `min_tests`, `red_tests` and both path lists are read from this front-matter. `BASE` is required
once `status: in_progress`.

## Scope changes
None.
