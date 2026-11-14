# 0027. Fixture capture and connector content (C6)

Status: accepted · Date: 2026-11-14

## Context
Replay of the user's real instances is the owner's replacement for a dry run. The only recordings were masked screen
observations: titles, URL hosts and masked text. Those are not connector responses and not the outputs he produced, so
there was nothing to replay for "Stripe payouts → sheet rows" ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P0-3).

## Decision
- The fix designer works in this order: the user picks an option → **connect apps** (opportunity state
  `needs_connection` until every connection the brief needs exists) → **fixture capture** (state
  `capturing_fixtures`) → brief, checks and held-out check (`designing`) → `ready_for_approval` → OK, build.
- **Fixture capture** uses the gate in mode `read` only: read-only connector reads of the inputs of the last N real
  instances (default N = 6, minimum 3) and of the resulting state (the row he appended, the mail he sent). A fixture is
  the recorded reads plus the expected commit items. Instances are chosen from the task's history (observed instances
  from M5, or the user's description and dates in the hand-fed loop).
- This is real content, so it is a new data class **C6 connector content** ([SECURITY_PRIVACY.md](../SECURITY_PRIVACY.md#2-data-classes)).
  Retention 30 days from capture (`R-content`, `OFFLOAD_CONTENT_TTL_DAYS`, [OQ-02](../OPEN_QUESTIONS.md#oq-02-raw-ttl-for-masked-observations-in-the-cloud)).
  A rebuild after that re-runs fixture capture.
- **Tokenisation**: before fixtures enter **any** sandbox (E2B or Docker), every string value from a connector is
  replaced reversibly with a token `tok_` + 12 hex, stable within the fixture set. The token map
  (`fixture_token_maps`) stays in Postgres, encrypted under the broker's key, and never enters a sandbox. Replay
  asserts commit items in token space. Numbers, dates and enums stay as they are when the brief's checks need them.
- If fewer than 3 instances can be captured, the build says so and relies on the check set and the held-out check.
- C6 rows carry `member_id` and fall under the member wall ([ADR 0013](0013-tenancy-and-rls.md)).

## Consequences
- Fixture capture needs the connections first, so connecting apps moves before the build in the UI.
- Fixture capture spends design budget only on model calls (none needed for plain reads).
- Sandbox providers see token-shaped data, not his customers' names or amounts as strings.

## Alternatives considered
- Replay from screen observations (the previous version): there is no connector data in them.
- Run replay only on Offload's own infrastructure with real values: possible later, but tokenisation is cheaper and
  works with every provider.

## Sources
[Design review C (2026-11-14)](../SOURCES.md#design-review-c), P0-3; old `brain/src/workflows/read-fetch.ts`, `workflows/observed.ts`.
