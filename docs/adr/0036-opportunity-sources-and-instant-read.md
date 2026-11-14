# 0036. Opportunity sources and the instant read

Status: accepted · Date: 2026-11-14

## Context
The first opportunity needed a week of capture and week records. PR #42's onboarding had an "instant read" that used
connected-app history on day one (ONB§7 screen 9a), and the owner can name a task himself. Manual opportunities existed
only as an MCP tool (review-c P1(1)).

## Decision
- `opportunities.source` is one of:
  - `finder`: observed and ranked by the opportunity finder (M5);
  - `manual`: typed by the user through `POST /v1/opportunities` (M2). This is how the hand-fed loop starts;
  - `instant_read`: on day one after he connects apps, a read-only scan (gate mode `read`) of the last 30 days of
    connector metadata (for example how often the same kind of mail is sent or rows are appended) proposes candidates
    with grade C estimates (M5);
  - `agent`: proposed by another agent through the Offload MCP server (M8).
- Text from `manual` and `agent` sources is untrusted: it is masked server-side (names to per-run placeholders) and
  leak scanned before storage, and it reaches models only inside untrusted-content blocks.
- All sources feed the same fix designer and build path. Instant-read data is C6 connector content (30 days).
- Estimates from `manual` and `instant_read` are labelled "estimated" until capture measures the task.

## Consequences
- M2 can run the whole build and run half of the loop without capture.
- The ranking formula applies to every source; manual opportunities are not ranked against observed ones until M5.

## Alternatives considered
- Wait for a week of capture (the previous version): the risky half of the product would be proven last.

## Sources
Review-c P1(1), §9; PR #42 ONB§7; review-a #67 (source column, masking at the MCP edge).
