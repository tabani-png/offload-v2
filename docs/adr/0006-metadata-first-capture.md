# 0006. Metadata-first capture, fail closed

Status: accepted · Date: 2026-11-14 · Carries over old ADR 0003

## Context
Watching a screen is sensitive. Most of the signal Offload needs is metadata.

## Decision
- The observer records app, window title, URL host, idle state and per-minute input **counts** (keys and clicks
  counted, never which keys). Text is read by on-device OCR only when the screen changes, then masked, truncated to
  8000 characters and de-duplicated by hash.
- Built-in exclusions (password managers, authenticators, banking apps and domains, private windows) and user
  exclusions ("Never watch") are applied before capture. An excluded window yields the app name only.
- Secure input (password fields) pauses text capture.
- Privacy fails closed: if masking fails or exclusions cannot be read, the observer records metadata only for that tick.
- The observer has no network code, enforced by a test that bans networking APIs in its sources. The uploader is a
  separate component of the Mac client that reads only the masked store.

## Consequences
- Understanding must work from metadata plus masked text. Images are optional ([OQ-04](../OPEN_QUESTIONS.md#oq-04-keyframes-to-the-cloud)).

## Alternatives considered
- Continuous screenshots to the cloud (Kortix Capture, screenpipe style). Rejected: privacy and cost.

## Sources
Old ADR 0003, 0007; old `engine/` (no-network test `S02NoNetworkTests`).
