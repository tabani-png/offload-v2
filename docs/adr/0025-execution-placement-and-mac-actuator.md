# 0025. Execution placement and the Mac actuator

Status: accepted, revised 2026-11-14 · Date: 2026-11-14

## Context
The thin Mac client did no running ([ADR 0007](0007-cloud-brain-thin-mac-client.md), previous version), so three of the
six build kinds had nowhere to run ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P0-1, [design review B (2026-11-14)](../SOURCES.md#design-review-b), P0-5). A cloud browser has no logged-in session; getting
one means storing passwords or session cookies, then fighting MFA, device binding, bot detection and a datacenter IP.
macOS Shortcuts, Apple Events, local files and desktop apps are unreachable from the cloud by definition. PR #42 A§9.5
designed a typed actuator for exactly this.

## Decision
- Every routine step carries `runs_on: cloud | device` ([ADR 0026](0026-routine-artifact-contract.md)). Placement by
  fix kind:

  | Fix kind | Runs | Notes |
  |---|---|---|
  | `api_integration`, `scheduled_routine`, `agent_workflow` | cloud runtime | OAuth connectors through the broker |
  | `script` | cloud if it only uses capabilities; device if it touches local files or apps | |
  | `browser_automation` | device, in the user's own logged-in browser, attended | cloud only for service accounts without MFA, opt-in |
  | `setup_change` | device (the user applies a reviewed patch; never the actuator) | |
  | `small_app` | hosted by the web app | not before M8 |

- **Mac actuator** (target `OffloadActuator`) accepts typed commands only. No command takes script text written by a
  model:
  - `shortcut.run { name, input? }`: runs one of the user's Shortcuts by name with the `shortcuts` command-line tool;
  - `appleevent.template { template, params }`: runs a template from a bundled, reviewed list (create reminder, create
    calendar event, create a Mail draft) with validated parameters; Automation permission asked just in time;
  - `ax.action { app, path, action, value? }`: presses, sets a value or picks a menu item on an element found by a
    recorded Accessibility path, only while the target app is frontmost and its bundle id matches the approved one;
  - `browser.step { profile, action, selector, value? }`: one step in the user's own browser profile, attended (the
    user watches, Esc stops it). The mechanism (extension with native messaging) is spike S6.
- **Device steps are commit-class.** They pass the same gate with the same item hash ([ADR 0004](0004-every-external-action-is-gated.md)).
  The item journal stays on the server, with `executor = 'device'`.
- **Device command queue**: after approval, the runtime writes the item to `device_commands` (state `queued`). The Mac
  long-polls `GET /v1/device/commands` with a device token, claims a command (`claimed`), re-checks the item hash
  against the approved one, runs it, and posts a signed `step_result` through ingest
  ([ADR 0020](0020-device-ingest-protocol.md)). See [API.md](../API.md#4-device-commands).
- **Timeouts**: device offline → run state `awaiting_device` (the workflow ends; the result starts a new one, per
  [ADR 0009](0009-durable-execution-on-postgres.md)). A command not claimed within 24 hours becomes `expired` and the
  item `failed_before_send`. A command claimed but with no result within 10 minutes makes the item `unknown`, never
  retried automatically.
- Lands in M6. The free-form `osascript` driver of the old repo is not carried forward.

## Consequences
- The Mac gets a small amount of execution code, behind typed commands and the same gate.
- Device steps run only while the Mac is awake and signed in; routines that need them say so in their definition.
- Browser automation in the cloud stays rare and opt-in.

## Alternatives considered
- Cloud Playwright with vault-held session cookies ([design review B (2026-11-14)](../SOURCES.md#design-review-b), P0-5 option). Rejected: MFA, bot detection, and a new
  class of stored secrets with no model in the data classes.
- Free-form AppleScript or shell on the Mac: a model could write the script; rejected.
- Leave these kinds out of v2: three of the six build kinds named by the owner would be missing.

## Sources
[Design review C (2026-11-14)](../SOURCES.md#design-review-c), P0-1; [design review B (2026-11-14)](../SOURCES.md#design-review-b), P0-5; PR #42 A§9.5, A§9.6; old `brain/src/connectors/computer/osa-driver.ts` (dropped).

## Revisions

- 2026-11-14 (final pass): `setup_change` is applied by the user, never the actuator; read-class device steps dropped, device steps are commit-class only, matching m1-05 (final-pass audit).
