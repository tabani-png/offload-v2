# 0038. Licenses: MIT core, Offload Enterprise License for `ee/`

Status: accepted; `ee/LICENSE` text is a draft pending legal review · Date: 2026-11-14 · Owner decision
[OQ-11](../OPEN_QUESTIONS.md#oq-11-license-for-the-core-and-for-ee)

## Context
The repository is public ([OQ-27](../OPEN_QUESTIONS.md#oq-27-publish-the-repository-publicly)), and until now `LICENSE`
and `ee/LICENSE` were placeholders that granted nothing: the code was visible, but nobody could use, copy or contribute
to it. The open-core layout is fixed by [ADR 0015](0015-open-core-layout-and-license-gating.md): core outside `ee/`,
Enterprise code under `ee/`, core never imports `ee/`, EE features switched on by an offline-verified license key. The
plan split is decided ([OQ-13](../OPEN_QUESTIONS.md#oq-13-plan-contents-and-prices)): single-player core free,
multiplayer paid. The recommended default had been Apache-2.0 for core.

Asked "License for the open core", the owner answered on 2026-11-14: "wtv clicky has done". farzaa/clicky's `LICENSE`
is MIT ("MIT License / Copyright (c) 2026 Farza"), read on 2026-11-14.

## Decision
- **Core: MIT (Expat).** The root `LICENSE` opens with a preamble in the PostHog style: content under `ee/` is under
  `ee/LICENSE`; third-party components keep the license their owners gave them (listed in `NOTICE`); everything else
  is MIT. The MIT text follows verbatim. Copyright: "Copyright (c) 2026 Muhammad Ali Tabani / consultance.ai".
- **`ee/`: the Offload Enterprise License**, a proprietary, source-available license written for Offload and modelled
  on PostHog's `ee/` license (Cal.com has used the same MIT core plus commercial `ee` pattern). Its terms:
  - production use only with a valid license key (`OFFLOAD_EE_LICENSE_KEY`) for the plan and seats used, and agreement
    to the Offload subscription terms (URL not yet published, marked TODO; see
    [OQ-17](../OPEN_QUESTIONS.md#oq-17-privacy-policy-terms-and-dpa));
  - copying and modifying for development and testing is allowed without a key;
  - modifications and patches belong to the licensor and may be used only under a valid key;
  - no selling, sublicensing or redistributing `ee/` code;
  - third-party components keep their own licenses;
  - MIT-style warranty and liability disclaimer.
- **The same in both hosting modes.** The license terms and the key check are identical on Offload Cloud and self-host
  ([ADR 0037](0037-hosting-cloud-and-self-host-parity.md)).
- **Draft.** `ee/LICENSE` carries the header "DRAFT: pending legal review before first paid customer (OQ-11)."
- **Manifests.** Core packages say `"license": "MIT"`. `ee/packages/*` say `"license": "SEE LICENSE IN ../../LICENSE"`
  (the path resolves to `ee/LICENSE`). The private workspace root keeps `"SEE LICENSE IN LICENSE"`, since it holds
  both.

## Consequences
- The core is OSI open source. Anyone may use, fork and host it, which [OQ-13](../OPEN_QUESTIONS.md#oq-13-plan-contents-and-prices)
  already accepts: a hosted clone gets the single-player product only.
- **No patent grant.** Unlike Apache-2.0, MIT has no explicit patent license or patent-retaliation clause. This is
  accepted: it matches the owner's choice and clicky, and keeps the license short and familiar.
- **Contributor terms.** Core contributions are taken under MIT, inbound = outbound (no CLA). Contributions to `ee/`
  need a contributor license agreement, because the licensor must own or be able to license `ee/` code commercially.
  Follow-ups:
  - write a CLA for `ee/` contributions and a `CONTRIBUTING.md` that states both rules, before accepting outside
    `ee/` pull requests;
  - legal review of `ee/LICENSE` before the first paid customer; then remove the DRAFT line;
  - publish the subscription terms and replace the TODO URL in `ee/LICENSE`.
- Old-repo code ([OQ-12](../OPEN_QUESTIONS.md#oq-12-relicensing-code-from-the-old-repo)) stays an open owner decision;
  the default is now to relicense it under MIT for core when ported (the owner owns it).
- Third-party Apache-2.0 components listed in `NOTICE` keep their Apache-2.0 terms; MIT core is compatible with using
  them.
- `scripts/check-license-boundary.sh` is unchanged: it checks imports, not license text.

## Alternatives considered
- Apache-2.0 core (the previous default): explicit patent grant, but not what the owner chose.
- AGPL-3.0 core: protects against hosted clones, but deters adoption and conflicts with a permissive open core.
- Fair-code core (n8n Sustainable Use): not OSI open source; closed by OQ-13.
- BSL for `ee/`: time-delayed open source; more moving parts than a plain commercial license.

## Sources
Owner answer 2026-11-14 ([OQ-11](../OPEN_QUESTIONS.md#oq-11-license-for-the-core-and-for-ee)); farzaa/clicky `LICENSE`
(MIT); PostHog root `LICENSE` and `ee/LICENSE` ([PostHog/posthog](https://github.com/PostHog/posthog)); Cal.com's MIT
core and commercial `ee` ([calcom/cal.com](https://github.com/calcom/cal.com)); [OPEN_CORE.md](../OPEN_CORE.md#1-license).
