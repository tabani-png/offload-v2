# Product

Offload is a product of consultance.ai. Words follow [GLOSSARY.md](GLOSSARY.md).

## 1. Vision

Offload takes the small back-office and admin work a person does again and again, and makes it run by itself. It does
not rebuild tools that already exist. It joins them: MCP servers, SaaS APIs, Composio toolkits, and a browser when
there is nothing else.

The loop:
1. A thin Mac client watches how you work, privately. It masks what it sees on your Mac before anything leaves.
2. A cloud brain learns your day, your goals and your history. It keeps a long-term, third-person picture of you, not
   your screen.
3. It spots work you repeat and ranks fixes against your goals. The numbers come from code.
4. You press **OK, build**. Offload builds the fix test-first in a sandbox, checks it against tests it never showed the
   builder and against your own past instances, and gets it ready to ship. A build costs at most $4.00.
5. You say OK a second time to install it. It runs. It asks before it sends anything until it has earned your trust.
6. It measures the hours it saves and tells you, every week, next to what it estimated.

Status: architecture only. Nothing below is built yet. See [ROADMAP.md](ROADMAP.md).

## 2. Personas

**Muhammad, the first user (solo operator).** Founder in Toronto. Runs consultance.ai and builds Offload. Lives in
Cursor, Chrome, Slack, Gmail and coding agents. His week mixes building, reviewing agent output, customer follow-ups,
finance admin and outreach. He wants fewer hours on admin and more on shipping. He is tenant of one for M1 to M6.

**Pro team lead getting into AI.** Runs a team of 3 to 20 at a small company. Knows the team repeats the same admin
work but does not have time to script it. Wants fixes that are safe to share across the team, a shared weekly view of
what was saved, and no surprise sends.

**Enterprise admin, security lead and auditor.** Needs SSO and SCIM, policy control over what may run unattended,
approvals by more than one person, an audit trail that can be exported and verified, data residency, and a deployment
option inside their own cloud. The auditor reads, never acts.

## 3. Jobs to be done

Concrete back-office examples Offload should handle. The fix kind is a likely first guess; the fix designer decides in
code from the evidence.

| When I... | I want to... | Likely fix kind |
|---|---|---|
| copy Stripe payouts into the finance sheet every week | have the rows appended for me, and only check them | `scheduled_routine` (`sheet.append`) |
| write the same customer follow-up after every call | get a draft in my tone ready to send with one tap | `agent_workflow` (`mail.send`) |
| review every coding-agent PR the same way | get a pre-read that flags missing tests and risky files | `script` or `small_app` |
| re-find the same 4 docs for each project | open a pinned set per project | `setup_change` |
| file receipts from email into the accounting tool | have bills created from attachments, asked before posting | `api_integration` (`accounting.bill`) |
| move candidates between stages after each interview | have the stage moved and a note added after I confirm | `api_integration` (`ats.move_stage`, `crm.note`) |
| export a report from a web app with no API every Monday | have it downloaded and filed | `browser_automation` |
| do a step that adds nothing (for example re-typing a status already in the tool) | be told plainly to stop, with the evidence | `remove_step` |
| do work that is the job itself (deep work, real conversations) | be left alone | `leave_alone` |

## 4. Screens

From the approved mockups. The web app mirrors them for Pro and Enterprise.

- **Onboarding**: what it watches and never keeps → permissions (Screen Recording, Accessibility, Input Monitoring)
  that tick live every 1.5 s, continue with any missing → "Here's your last 10 minutes" computed on the Mac with the
  pointer flying to it → what you do → goals (up to 3) → drains → rhythm and boundaries ("Never watch") → optional
  recordings import → how hands-on (suggest only, draft for me, run fixes I've approved) → done ("your first review
  lands Friday at 4:00 PM"). Every question can be skipped.
- **Today**: a day grid (categories × 15-minute cells, switch bursts), "what you did", "keeps coming back this week",
  and **one suggested fix at a time** with options 1 / 2 / 3, one recommended, and "leave it alone". Tap any number to
  see how it was counted.
- **Weekly review**: one sentence about what changed, a few tiles compared with your usual week, your goals with
  trends, and up to 4 one-tap questions ("Is D. in these threads Dana?", "Keep it?", "Build the PR pre-read tool
  next?"). Charts sit one tap deeper.
- **Build progress**: stages (plan locked, tests written, building, matches what you asked for, ready to ship), checks
  running with a failure being fixed on screen, time and spend against the $4.00 cap, and a separate **Install**
  button. Nothing ships without that second OK. Rows: [OQ-10](OPEN_QUESTIONS.md#oq-10-build-progress-screen-rows).
- **Routines**: what is running, what it did, what it is waiting for you to approve, hours saved (measured) next to
  the estimate, pause, undo.

## 5. Plans

Free (open core, self-host or personal), Pro (hosted, teams), Enterprise (governance, SSO/SCIM, deployment options).
Contents in [OPEN_CORE.md](OPEN_CORE.md#2-feature-split). Prices are the owner's decision
([OQ-13](OPEN_QUESTIONS.md#oq-13-plan-contents-and-prices)).

## 6. UI direction

Approved direction (from the pricing page learnings and the mockups):
- Light paper field `#f4f5f2`, dark floating chrome (`#0c1422`, `#151f2f`), real product UI, never illustration or
  stock images.
- Geist and Geist Mono. Tight grotesk headlines (Geist 600, about −0.04em). Tabular numbers.
- Dusk gradient (blue → rose → amber) as the brand colour. Status dots: blue working, amber needs you, green done.
- Motion shows product state only (typing, focus moving, ticks, dots changing, a toast arriving). Transforms and
  opacity only. Each sequence plays once. The final state is the no-motion state; reduced motion is respected.
- Checkmarks scale 0.25 → 1 with opacity and blur 4 → 0; buttons press to 0.96.
- Calm copy. Lowercase captions with "·" separators ("counted on your mac · no model call"). Sentence case for
  headlines and labels.
- The build screen shows check groups by default; worker rows appear only on fan-out
  ([OQ-10](OPEN_QUESTIONS.md#oq-10-build-progress-screen-rows)).

## Copy rules

- Lead with the outcome in the fewest words. Short sentences.
- Describe mechanics plainly ("Blue is working, amber needs you, green is done.").
- **No em dashes in product copy.** Use a full stop or "·".
- **Banned words**: generous, unlock, seamless, powerful, at scale, robust, "everything you need", "built for teams that…".
- **Never say "dry run"** or "preview run" ([ADR 0016](adr/0016-no-dry-run.md)). Say what happens: "tested against
  your last 6 invoices", "asks before it sends".
- "OK, build" means ready to ship. Use it only where the button exists.
- Every number is measured or labelled "estimated". No invented metrics, customers, logos or testimonials.
- Unbuilt features carry a "coming" label.
- `scripts/check-copy.sh` enforces the banned words, "dry run" and em dashes in product surfaces.

## 7. Non-goals

- Not a screen recorder or a searchable screen history. No raw screen data is kept in the cloud.
- Not employee surveillance. No ranking of people. Per-person views for teams only under the compliance rules in
  [SECURITY_PRIVACY.md](SECURITY_PRIVACY.md#12-compliance-notes-not-legal-advice), and only if the owner decides to offer them.
- Not a general chat assistant. Offload acts on repeated work it has observed or been told about.
- Not a new integration platform. It uses MCP servers, Composio and APIs that exist.
- Not autonomous by default. Every commit asks until a policy and the user say otherwise.
- No dry-run ceremony.
- No Windows or Linux client in v2.
