# 0007. Cloud brain, thin Mac client

Status: accepted, revised 2026-11-14 · Date: 2026-11-14 · Supersedes the old local-first brain (old `plan/plan.md` "Brain: Bun/TS on 127.0.0.1")

## Context
The old brain ran on the Mac. That limits the user model (7 days of raw data, then nothing), makes builds unsafe on the
user's Mac (old ADR 0013: same-uid `KERN_PROCARGS2` leak), and blocks teams and the web app. The owner wants the brain
on a cloud backend and the Mac client to be capture and UI only. Some fixes still have to act on the Mac itself
(Shortcuts, local apps, the user's logged-in browser).

## Decision
- The Mac client does: capture, on-device masking and pseudonyms, local encrypted buffer, signed upload through the
  Mac egress guard, UI (Onboarding, Today, Weekly review, Build progress, approvals), notifications, the in-window
  pointer, and, from M6, the **actuator** that runs typed device commands for approved items
  ([ADR 0025](0025-execution-placement-and-mac-actuator.md)). It does no understanding, ranking or building.
- The cloud does: ingest, understanding, the long-term user model, opportunity finding, fix design, building in
  sandboxes, running cloud routine steps, governance and measurement. The routine runtime decides where each step runs.
- What leaves the Mac by default, said plainly: **text from the screen is uploaded** (decided by the owner on
  2026-11-14: "Yes, masked text can go to the cloud", [OQ-28](../OPEN_QUESTIONS.md#oq-28-masked-screen-text-to-the-cloud)), masked and pseudonymised, along
  with app names, window titles, URL hosts, idle transitions and the user's answers. Pixels, unmasked text and
  keystrokes never leave ([SECURITY_PRIVACY.md](../SECURITY_PRIVACY.md#3-what-leaves-the-mac)). Masked keyframes
  stay on the Mac unless the user opts in ([OQ-04](../OPEN_QUESTIONS.md#oq-04-keyframes-to-the-cloud)).
- Cloud retention of uploaded observations is split: metadata 30 days, text snapshots 7 days ([OQ-02](../OPEN_QUESTIONS.md#oq-02-raw-ttl-for-masked-observations-in-the-cloud)).
- The Mac keeps a 7-day encrypted local buffer (AES-256-GCM day files, keys wrapped by a Keychain master key) so
  uploads survive being offline, and a 7-day local egress ledger of what was sent ([ADR 0035](0035-mac-egress-guard-and-ledger.md)).
- Offline: capture continues, uploads queue, UI shows the last synced state, device steps wait (`awaiting_device`).

## Consequences
- Builds run in cloud sandboxes, which fixes the same-uid leak class for builds.
- The privacy promise changes from "nothing leaves your Mac" to "masked, pseudonymised screen text and metadata leave
  your Mac; pixels do not". Onboarding copy must say so.
- The Mac app no longer bundles a 395 MB brain (old ADR 0014 dropped).

## Alternatives considered
- Keep a local brain and sync derived data. Rejected by the owner; also keeps builds on the Mac.
- Hybrid with local understanding. Rejected for v2: two brains to keep in step.
- No execution on the Mac at all (the previous version). Rejected: three fix kinds had nowhere to run ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P0-1).

## Sources
Owner brief; old ADR 0013, 0014, 0103; [product spec (M0 to M9)](../SOURCES.md#product-spec-m0-to-m9) section 3; PR #42 A§9.5.

## Revisions
- 2026-11-14: the Mac runs typed device commands from M6 ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P0-1, [design review B (2026-11-14)](../SOURCES.md#design-review-b), P0-5); plain wording that screen
  text is uploaded and split C1 TTLs ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P1(7)); local egress ledger.
- 2026-11-14 (decision pass D): masked screen text upload confirmed by the owner (OQ-28); pixels stay on the Mac by
  default, keyframes opt-in.
