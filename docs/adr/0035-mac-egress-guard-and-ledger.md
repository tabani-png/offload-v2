# 0035. Mac egress guard and local egress ledger

Status: accepted · Date: 2026-11-14

## Context
PR #42 promised one egress guard, a readable ledger of what was sent, and fail-closed redaction (A§6.2, A§6.4, G9). v2
moved the brain to the cloud and uploads masked screen text; the guard and the ledger were lost, and the server's
"second" leak scan used the same detectors as the device (review-c P1(7)). The controls that still apply are kept.

## Decision
- **The Mac uploader is the egress guard.** It sends to one destination (the configured Offload API host), only
  payloads that validate against closed schemas (`additionalProperties: false`), runs the detectors again on every
  object before sending, and fails closed: an error anywhere means nothing is sent and the count shows in the app.
- **Local egress ledger**: every uploaded batch is appended to a sealed local ledger kept 7 days: time, destination,
  kind, object count, bytes, redaction counts and exactly what left. The app shows it as "What was sent".
- **Server-side egress lint**: a lint rule and a test (`EGRESS: fetch appears only in allowlisted modules`) ban `fetch`,
  `Bun.connect`, `node:http`, `node:https` and `node:net` outside: the model router, the broker, the sandbox provider,
  the model egress proxy, the OIDC client and outbound webhooks.
- **Server leak scan is a transport check.** It runs the same rules as the device, so it catches transport and client
  bugs, not detector misses. An **on-device model pass** is evaluated in M3 by PR #42's decision rule (A§6.3): adopt it
  if it raises name and address recall by at least 3 points at under 50 ms per 1,000 characters on an M1 Air; rules
  stay the floor.
- **Canary tests**: a canary string placed in capture, connector and fixture test data must never appear in logs, and
  never in any database column outside the **content-column allowlist**, which names the columns allowed to hold C1,
  C2 or C6 content.

## Consequences
- The user can see what left his Mac, which is the trust feature PR #42 called G9.
- New server code that needs the network must live in an allowlisted module or change the allowlist in review.

## Alternatives considered
- Trust the server scan as an independent check (the previous version): it fails where the device failed.
- No local ledger: cheaper by a few lines, loses the trust feature.

## Sources
Review-c P1(7); PR #42 A§6.2, A§6.3, A§6.4, A§13.1, A§13.2 (V5/V6 canaries).
