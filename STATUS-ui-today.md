# Status (w1/ui-today)

One line per slice step: slice | decision | tests | reviewer verdict.

- 2026-11-22 12:59 m3-11-mac-today-live | built by Claude Opus 5.5, 3 review round(s) | 88 tests | reviewer: VERDICT: PASS (logs: review3)

## CI notes
- 2026-11-22 CI run 1 (run 45052468488, `mac`): the module built; the test target failed to compile on
  M311.swift:360 and :362, `instance method 'lock'/'unlock' is unavailable from asynchronous contexts`: the test
  double `M311Builds.answerOpportunity` (an `async` BuildsClient method) called `NSLock.lock()`/`unlock()`
  directly. Fixed in m3-11 (d33e9b2): the append goes through a synchronous `record` helper, as `count()` already did;
  no expectation changed. A scan of every `lock()`/`unlock()` in apps/mac finds no other async caller.
  - `Swift slice m3-03-mac-signing-sparkle` failed with `only 0 swift tests passed, need 4`: the same compile error
    (its step rebuilds the shared test target), not an m3-03 problem. No change.
  - `durable: workflow "sleeper"`/`"waiter-msg" failed (Error)` and the p43b `(pass)` line are logs of passing
    `core` tests; `core` passed. No change.
  - Found while verifying: m3-11's verify.sh BASE (`d3d6651`) left the history when m3-10 was rebased, so the scope
    check walked m3-10's commits and failed on its TodayLive placeholder (ddb9120). BASE is now `e80962a` (d31fec8).
  - Not yet seen green: the file that failed compiled no further than type checking, so region-isolation (SIL)
    diagnostics for the M311 test files run for the first time in the next run.
- 2026-11-22 13:16 today | CI green on e183e7dcb3d7a917ac8c2dda98493104a703e6d2 | runs: mac-artifact=success, ci=success
- 2026-11-22 13:38 today-api | CI green on 158e89e0b9f9e2f7f51361a6a779a8d0a912e1cd | runs: ci=success, mac-artifact=success
- 2026-11-22 13:38 m3-11-mac-today-live | extra review to round 3 | reviewer: VERDICT: PASS
- 2026-11-22 13:44 today-more | CI green on 55324afa540da3c16e2da9814c76ee419ec41838 | runs: mac-artifact=success, ci=success
- 2026-11-22 13:52 m3-11-mac-today-live | extra review to round 4 | reviewer: VERDICT: PASS
