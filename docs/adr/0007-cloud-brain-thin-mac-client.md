# 0007. Cloud brain, thin Mac client

Status: accepted · Date: 2026-11-14 · Supersedes the old local-first brain (old `plan/plan.md` "Brain: Bun/TS on 127.0.0.1")

## Context
The old brain ran on the Mac. That limits the user model (7 days of raw data, then nothing), makes builds unsafe on the
user's Mac (old ADR 0013: same-uid `KERN_PROCARGS2` leak), and blocks teams and the web app. The owner wants the brain
on a cloud backend and the Mac client to be capture and UI only.

## Decision
- The Mac client does: capture, on-device masking, local encrypted buffer, signed upload, UI (Onboarding, Today,
  Weekly review, Build progress), notifications, and the in-window pointer. It does no understanding, ranking,
  building or running.
- The cloud does: ingest, understanding, the long-term user model, opportunity finding, fix design, building in
  sandboxes, running routines, governance and measurement.
- What leaves the Mac by default: masked observations (`C1`) and the user's answers. Raw frames, unmasked text and
  keystrokes never leave ([SECURITY_PRIVACY.md](../SECURITY_PRIVACY.md#3-what-leaves-the-mac)).
- The Mac keeps a 7-day encrypted local buffer (AES-256-GCM day files, keys wrapped by a Keychain master key) so
  uploads survive being offline.
- Offline: capture continues, uploads queue, UI shows the last synced state.

## Consequences
- Builds run in cloud sandboxes, which fixes the same-uid leak class for builds.
- Masked observations now sit in the cloud for the raw TTL (default 30 days, [OQ-02](../OPEN_QUESTIONS.md#oq-02-raw-ttl-for-masked-observations-in-the-cloud)).
  The privacy promise changes from "nothing leaves your Mac" to "only masked metadata and text leave your Mac".
  Onboarding copy must say so.
- The Mac app no longer bundles a 395 MB brain (old ADR 0014 dropped).

## Alternatives considered
- Keep a local brain and sync derived data. Rejected by the owner; also keeps builds on the Mac.
- Hybrid with local understanding. Rejected for v2: two brains to keep in step.

## Sources
Owner brief; old ADR 0013, 0014, 0103; `/workspace/offload-app/spec.md` section 3.
