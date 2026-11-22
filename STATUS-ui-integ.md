# Status (w1/mac-integration)

One line per slice step: slice | decision | tests | reviewer verdict.

- 2026-11-22 13:01 m3-14-mac-app-integration | review rounds to 6 | reviewer: VERDICT: CHANGES

## CI notes

- CI 2 (run 45053654551, mac job): both root causes were in m3-14's tests and are fixed (bb6d481, 6d223e8; guard
  1bb23a2). The other "FAIL tests for ..." lines in that job (NONET, MASK, PSEUDO, EXCLUDE, STORE, UPLOAD, EGRESS from
  m3-02, SPARKLE from m3-09) come from the same OffloadMacTests compile failure, not from those slices. The crash stopped
  the frontend batch before M314.swift, M314ExcludeTests, NowTests, RuntimeTests and UploaderImportTests were
  SIL-checked; they were read for the same patterns by hand, but CI 3 is their first full compile.
