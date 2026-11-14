---
id: m5-03-model-router
title: Model router - the one egress for product model calls, with the person-name masking second pass, leak scan, budgets, escalation, label-only structured output and the optional local tier
milestone: M5
status: ready
depends_on: [m1-02-contracts-ingest, m1-03-tenancy-rls, m3-01-ingest-batches]
parallel_safe: true
human_gated: false
model_tier: sonnet
size: M
parallel_group: M5-A
owns: [services/brain/src/models/**, services/brain/config/**, packages/masking/src/names/**, packages/testkit/src/models/**, packages/testkit/fixtures/masking/**]
verify: bash slices/m5-03-model-router/verify.sh
min_tests: 26
paths_in_scope: [services/brain/src/models/**, services/brain/config/**, services/brain/tests/m5-03-model-router/**, packages/masking/src/names/**, packages/masking/tests/m5-03-model-router/**, packages/testkit/src/models/**, packages/testkit/fixtures/masking/**, slices/m5-03-model-router/**, package.json, bun.lock]
paths_out_of_scope: [ee/**, apps/**, services/api/**, services/broker/**, services/builder/**, services/runtime/**, services/brain/src/understanding/**, services/brain/src/records/**, services/brain/src/opportunities/**, packages/masking/src/index.ts, packages/testkit/src/index.ts, packages/db/**, packages/contracts/**, docs/adr/**]
red_tests: [ROUTER, NAMES, BUDGET, ESCALATE, LABEL, LOCAL]
---

# m5-03-model-router

## Summary
The single egress for product model calls ([ADR 0021](../../docs/adr/0021-model-router-and-builders.md),
[ARCHITECTURE section 17](../../docs/ARCHITECTURE.md#17-model-router)), with the second masking pass of
[ADR 0005](../../docs/adr/0005-masked-text-only-reaches-models.md) and
[SECURITY_PRIVACY section 5](../../docs/SECURITY_PRIVACY.md#5-masking), labels instead of numbers
([ADR 0003](../../docs/adr/0003-numbers-come-from-code.md)) and untrusted wrapping
([SECURITY_PRIVACY section 7](../../docs/SECURITY_PRIVACY.md#7-prompt-injection-defenses)). Owns the three ROADMAP
[M5](../../docs/ROADMAP.md#m5-observed-loop) `ROUTER:` acceptance tests and the "Model router refuses unmasked names
and secrets" row of [SECURITY_PRIVACY section 13](../../docs/SECURITY_PRIVACY.md#13-security-tests-that-must-exist).
Security-sensitive (masking): it gets a security review before `done`.

**Tests use `packages/testkit` fakes only.** No test calls a real model or the Anthropic API: the provider is
`FakeModelProvider`, the HTTP backend is tested against `fakeMessagesApi()` on 127.0.0.1, the budget ledger is
`InMemoryBudgetLedger`, the clock is the testkit fake clock. There is no `LIVE:` test in this slice.

**Depends on m3-01** (not only M1 as the ROADMAP task row said; ROADMAP is updated): the leak scan on every model
request is m3-01's `packages/masking` transport check, imported, not changed.

**Ports** ([MIGRATION section 2.6](../../docs/MIGRATION.md#26-brain-bun--ts--services-packages)):
old `brain/src/models/router.ts` is **keep** (ids and prices move to config); `privacy/{names,lexicon,policy}.ts` is
**keep** into `packages/masking/src/` (here `packages/masking/src/names/`) with its tests; the provider backends
(`models/{model,factory,api-backend,…}.ts`) are **rewrite**. From PR #45, as
[MIGRATION section 5.6](../../docs/MIGRATION.md#56-pr-45-featbuild-loop-s35-ok-build) says: `models/local.ts` →
the router's local tier, with the carried red test `LOCAL: refuses any host that is not loopback`. Nothing else from
PRs #43 to #45. Ports need the relicensing default of
[OQ-12](../../docs/OPEN_QUESTIONS.md#oq-12-relicensing-code-from-the-old-repo) and operator item O14 (old test
canaries confirmed fake) before old tests are copied.

## Contract
- Does not edit `services/brain/src/index.ts` or `services/brain/tests/smoke.test.ts`: the first `services/brain`
  slice (m2-01) replaces them, and m5-01 owns the brain barrel in M5-A. Callers import the router by subpath
  (`@offload/brain/src/models/router.ts`). The same goes for the `packages/masking` and `packages/testkit` barrels.
- No new dependency. `fetch` is used only in `services/brain/src/models/providers/` (the router is on the server
  egress allowlist in [SECURITY_PRIVACY section 9](../../docs/SECURITY_PRIVACY.md#9-secrets)).
- **Config** `services/brain/config/models.json` (validated by zod at load; env overrides only for the local URL):
  ```
  { "tiers": { "opus":   { "id": "claude-opus-5-5",   "usd_per_mtok_in": null, "usd_per_mtok_out": null, "usd_per_mtok_cache_read": null },
               "sonnet": { "id": "claude-sonnet-5-5", ... }, "haiku": { "id": "claude-haiku-5-5", ... } },
    "routes": { "design": "opus", "check_write": "opus", "verify": "opus", "understand": "opus", "explain": "opus",
                "build": "sonnet", "draft": "sonnet", "model_step": "sonnet",
                "classify": "haiku", "caption": "haiku", "label": "haiku" },
    "local_routes": ["classify", "caption", "embed"],
    "max_usd_per_call": { "<route>": <number> } }
  ```
  Ids are exactly the three in ARCHITECTURE section 17. **Prices are committed as `null`**: a route whose model has no
  configured price is refused before any call (`needs_you`, reason `prices_not_configured`). The owner or operator
  fills prices from the provider's price page in a reviewed config change; no doc states a price.
- **Allowlist**: the router refuses any model id not in `tiers` (including `claude-fable-5-2`, which is dev-time only,
  [OQ-19](../../docs/OPEN_QUESTIONS.md#oq-19-what-is-fable-52-and-should-it-shape-the-architecture)) before sending.
- **Entry point** (`services/brain/src/models/router.ts`):
  `route(call: { tenant_id, member_id?, run_id?, route, system, messages, schema?, max_tokens, own_name?,
  run_budget_usd? }, deps: { provider, ledger, scanner, audit, clock, config })`. Order on every call:
  1. **Untrusted wrapping**: callers pass untrusted text through `untrusted(source, text)`, which strips Unicode format
     characters (category Cf) and escapes `</untrusted>`; the router refuses a message that contains an unescaped
     closing tag.
  2. **Masking second pass** (`packages/masking/src/names/`): placeholder-shaped input (`<person:…>`) becomes `<name>`;
     person names the device missed become `<person:TAG.N>` / `<person:TAG.N.first>`; the member's own name becomes
     `<person:TAG.me>` (`own_name_to_models = 'mask'` default). `TAG` is a random 4-letter tag per run. Device
     pseudonyms (`<person:h_…>`) and router placeholders pass unchanged. The per-run name map lives in memory for the
     run only and is never logged, returned or stored.
  3. **Leak scan**: m3-01's transport check runs over the masked request; a hit refuses the call and writes audit
     `privacy.leak_blocked` through the `audit` port (ids and hashes only).
  4. **Budget** (`BudgetLedger` port: `spentThisMonth(tenant)`, `spentThisRun(run)`, `reserve`, `settle`): worst-case
     reservation = input tokens (counted by the provider adapter's estimator) × input price + `max_tokens` × output
     price. Refused when it exceeds `max_usd_per_call[route]`, the run's remaining `run_budget_usd`, or the tenant's
     remaining monthly budget (`tenants.monthly_model_budget_usd`, default $50 per
     [OQ-05](../../docs/OPEN_QUESTIONS.md#oq-05-model-provider-terms-and-monthly-model-budget), UTC calendar month).
     At ≥ 80% of the monthly budget, `classify` and `caption` go to the local tier if `OFFLOAD_LOCAL_MODEL_URL` is
     set; at 100%, every paid route stops with `needs_you` (reason `monthly_budget_reached`) and no call is made.
     After the call the reservation is settled with actual usage; one ledger entry per call with
     `idempotency_key = call id`, scope `brain` (or `run`/`design` as the caller says), plus the `model_usage` day row.
  5. **Send** to the tier's provider. `stop_reason` is checked first.
  6. **Escalation**: on `refusal`, `max_tokens` (cut off) or output that fails `schema`, retry one tier up (haiku →
     sonnet → opus), each attempt budgeted as in step 4; after opus fails, `needs_you` (reason `escalation_exhausted`).
     Never down. `modelStepTier(history)` (pure): an item-level model step drops sonnet → haiku after 5 clean runs and
     goes back to sonnet on any edit, failure or refusal.
  7. **Labels**: a `schema` passed to `route` must be label-only: `assertLabelSchema(schema)` refuses any number,
     integer or free string field that is not an enum (strings for names or text fields are allowed only when the
     schema marks them `x-offload-text`). Code maps labels to numbers with tables next to the caller
     (`mapLabel(table, label)`); an unknown label throws.
- **Providers** (`services/brain/src/models/providers/`): `ModelProvider { send(req) → { content, stop_reason, usage }
  }`; `anthropicMessages(baseUrl, keySource)` speaks the Messages API (tool-less, structured output, adaptive thinking,
  no forced `tool_choice`), with the key read once at start from the process environment by the composition root, never
  logged (BYOK through the broker is a later slice); `localOpenAICompatible(url)` for the local tier.
- **Local tier**: off unless `OFFLOAD_LOCAL_MODEL_URL` is set. Accepted hosts: loopback (`127.0.0.0/8`, `::1`,
  `localhost`) and private networks (RFC 1918, `fc00::/7`), as ADR 0021 and `.env.example` say for exo clusters;
  any other host is refused at config load. Never used for `build`. MIGRATION 5.6 carries PR #45's test as
  "refuses any host that is not loopback"; this slice widens it to private networks per ADR 0021 and keeps the
  loopback case.
- **Fakes** (`packages/testkit/src/models/`): `FakeModelProvider` (scripted replies per tier: ok, refusal, cut-off,
  invalid JSON; records every request it receives), `fakeMessagesApi()` (a `Bun.serve` on 127.0.0.1 that returns
  canned Messages API responses and records request bodies), `InMemoryBudgetLedger`, `recordingAudit()`.
  Corpus: `packages/testkit/fixtures/masking/names-heldout.jsonl`, synthetic only (generated names, no real people),
  at least 200 lines, with a maximum miss rate set in the test (default 2%; the masking slice in M3 may tighten it).

## Red tests (write these first, run them, see them fail)
Folders: `services/brain/tests/m5-03-model-router/` and `packages/masking/tests/m5-03-model-router/`.

| Tag | Test name | Asserts |
|---|---|---|
| ROUTER | ROUTER: a person name in a prompt reaches the provider as a placeholder (held-out corpus) | ROADMAP M5 test; miss rate ≤ the set maximum; `FakeModelProvider` request bodies |
| ROUTER | ROUTER: at 100% of the monthly budget paid routes stop with needs_you | ROADMAP M5 test; provider not called |
| ROUTER | ROUTER: a model returns a label and code maps it to a number | ROADMAP M5 test |
| ROUTER | ROUTER: a model id outside the allowlist is refused before sending | `claude-fable-5-2` and an unknown id |
| ROUTER | ROUTER: a leak scan hit refuses the call and writes privacy.leak_blocked | card number, sk-ant style key, email |
| ROUTER | ROUTER: untrusted text is wrapped, format characters are stripped and a closing tag cannot escape | |
| ROUTER | ROUTER: the HTTP backend sends a tool-less Messages request and reads stop_reason first | `fakeMessagesApi()` |
| ROUTER | ROUTER: each route uses the tier in models.json | |
| NAMES | NAMES: placeholder-shaped input becomes name before masking | `<person:abcd.1>` in input → `<name>` |
| NAMES | NAMES: the same name in one run gets the same placeholder and a new run gets a new tag | |
| NAMES | NAMES: the member's own name becomes the me placeholder by default | |
| NAMES | NAMES: device pseudonyms pass unchanged | `<person:h_0123456789abcdef>` |
| NAMES | NAMES: the per-run name map never appears in logs, ledger entries or the result | |
| BUDGET | BUDGET: a reservation above the run's remaining budget is refused and the provider is not called | |
| BUDGET | BUDGET: a route whose model has no configured price is refused | prices committed as null |
| BUDGET | BUDGET: at 80% of the monthly budget classify and caption go to the local tier when it is configured | |
| BUDGET | BUDGET: every call writes one ledger entry keyed by its call id and settles the reservation | retry with the same id writes once |
| BUDGET | BUDGET: an escalated call budgets each attempt | |
| ESCALATE | ESCALATE: a refusal from haiku retries on sonnet, then opus | |
| ESCALATE | ESCALATE: a cut-off reply or invalid structured output escalates one tier | |
| ESCALATE | ESCALATE: after opus fails the call ends needs_you and never goes down a tier | |
| ESCALATE | ESCALATE: a model step drops to haiku after 5 clean runs and returns to sonnet on an edit | `modelStepTier` |
| LABEL | LABEL: a schema with a number field is refused before any call | |
| LABEL | LABEL: an unknown label throws in mapLabel | |
| LOCAL | LOCAL: refuses any host that is not loopback or a private network | carried from PR #45, widened; public host refused, `127.0.0.1` and `10.0.0.5` accepted |
| LOCAL | LOCAL: the local tier is off when OFFLOAD_LOCAL_MODEL_URL is unset and never serves build | |

## Out of scope
The Postgres `BudgetLedger` adapter over `budget_entries` and `model_usage` (`budget_entries` is created with the
model egress proxy in m2-08; the adapter and the `model_usage` table land in a follow-up slice that this SPEC's
reviewer names); the model egress proxy (m2-08); BYOK keys through the broker; embeddings (m5-01); `GET /v1/budget`;
runtime `model` step execution (m2-10, which calls this router); keyframe captioning (opt-in, OQ-04); real prices
(owner input).

## Verify
`bash slices/m5-03-model-router/verify.sh` (no Postgres; fakes only).

## Scope changes
None.
