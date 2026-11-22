# 0039. Local analysis on the Mac in Local mode (amends 0007)

Status: proposed, needs Muhammad's sign-off
Date: 2026-11-22 · Amends [ADR 0007](0007-cloud-brain-thin-mac-client.md) · Slice m3-10-mac-recordings-analysis

## Context
[ADR 0007](0007-cloud-brain-thin-mac-client.md) makes the Mac a thin client: it "does no understanding, ranking or
building". On 2026-11-22 the owner asked for the test build to read his recordings folder (`~/screenwatch` archives,
`.mov` and `.mp4` screen recordings), analyse it on his Mac, and show the result, before the cloud backend is
connected. Until enrollment exists (m1-04, m3-02) there is no member token, so the test build runs in **Local mode**
([backend mode](../GLOSSARY.md) `.local`) and nothing can be uploaded. Without some analysis on the Mac the owner
cannot test Today, Weekly review or the recordings import at all. Slice m3-10 built that analysis; this ADR records it
as a decision rather than leaving it as a slice divergence.

## Decision
- **In `.local` backend mode the Mac counts and ranks its own data**, as **local insights**: active time per day and
  per app, sessions, focus blocks, switches, top apps and sites (host only), and the **things you repeat** with minutes
  per week, a confidence label and evidence; ranked with [ARCHITECTURE section 6](../ARCHITECTURE.md#6-opportunity-finder)'s
  factors (minutes per week, persistence over 8 ISO weeks, goal weight, confidence, the decline penalty from the weekly
  review answers kept on the Mac).
- **Code only.** Every number is a `Figure` with its arithmetic and evidence, computed by code
  ([ADR 0003](0003-numbers-come-from-code.md)). No model is called on the Mac or anywhere else for local insights; no
  sentence, name or label is generated. Ranking orders time spent; no saving is estimated and nothing is built or run
  (building stays in the cloud, ADR 0007, [ADR 0011](0011-sandboxed-build-workers.md)).
- **No upload.** Local insights, the imports they read and the weekly review answers stay on this Mac
  (`Application Support/Offload/OnDevice/`, folders 0700, files 0600, excluded from backups). In `.local` no API client
  exists, so no request can be built ([ADR 0035](0035-mac-egress-guard-and-ledger.md)'s egress guard is unchanged).
- **Masked data only.** Recordings are read with on-device OCR and masked before anything is stored, by the same rules
  that apply to anything that leaves the Mac ([ADR 0005](0005-masked-text-only-reaches-models.md),
  [ADR 0028](0028-stable-keyed-pseudonyms.md)): secrets, cards, account numbers and codes become placeholders; URLs keep
  their host; emails, phones and person names become pseudonyms. The masked text itself is not kept, only its hash;
  pixels, file names and paths are never stored. Never watch applies when insights are read. Until m3-02's
  `OffloadMasker.TextMasker` is merged, an interim masker with the same labels and pseudonym shape does this; the m3-14
  integration swaps it in.
- **Labelled.** Screens say "counted on this Mac" for local figures. Local figures never mix with cloud figures or with
  sample data ("Sample data: cloud not connected").
- **In `.cloud` backend mode** (an https API base URL and a member token): the on-device import is not built; the
  recordings import is m3-05's, through the uploader, as ADR 0007 describes; the screens read the brain and builds
  APIs, which do the understanding and ranking. Local insights are not shown as the person's figures in `.cloud`, and
  nothing computed locally is uploaded or sent to the brain. Data already analysed in `.local` stays on the Mac until
  the person removes it.

## Consequences
- ADR 0007's "no understanding or ranking on the Mac" holds in `.cloud` mode and no longer in `.local` mode. The Mac now
  holds a small deterministic engine (`apps/mac/Sources/OffloadMac/Analysis/`) and its tests; it has no networking API
  (test NONET).
- There are two rankings: the brain's (`.cloud`) and the Mac's (`.local`). They use the same factors but different
  inputs, so the same person can see different top repeats in the two modes. Screens say which one they show.
- More on-device data at rest (masked observations, answers). It is protected by POSIX modes and file protection, not
  yet by the store's AES-GCM day-file sealing; it moves into the sealed store with m3-02. A
  [SECURITY_PRIVACY.md section 13](../SECURITY_PRIVACY.md#13-security-tests-that-must-exist) review of the masker, the
  local sink and the local pseudonym key is required before m3-10 is done.

## Alternatives considered
- Keep the Mac thin and show sample data until the cloud is connected. Rejected by the owner: he must test with his
  own recordings.
- Upload imports to a cloud brain for the test build. Not possible before enrollment, and it would send data before the
  owner's consent screen ever runs.
- Use a model on the Mac to label or summarise. Rejected: numbers and decisions come from code (ADR 0003), and no model
  is needed to count and rank time.

## Sources
Owner brief 2026-11-22 (`prompts/common.md`, "The owner's goal"); slice `m3-10-mac-recordings-analysis` SPEC (Design note,
Scope changes, reviews 1 to 3); [ARCHITECTURE.md section 1](../ARCHITECTURE.md#1-mac-client).
