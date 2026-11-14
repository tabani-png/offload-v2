# 0021. Model router and builder models

Status: accepted, revised 2026-11-14 · Date: 2026-11-14 · Carries over old ADR 0009, 0008

## Context
Different jobs need different models. All model calls must be masked, budgeted and logged in one place. Model ids and
prices change often and are configuration, not decisions ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P2).

## Decision
- One **model router** module in the brain (`services/brain`, exported for the builder and runtime modules) is the
  only egress for product model calls. It masks ([ADR 0005](0005-masked-text-only-reaches-models.md)), budgets, logs
  usage to `model_usage` and `budget_entries`, and escalates. The model egress proxy is its sandbox-facing twin and
  enforces the build cap ([ADR 0030](0030-build-budget-at-egress-proxy.md)).
- **Model ids and prices are configuration**: `services/brain/config/models.json` with env overrides. The default
  route table (ids only) is in [ARCHITECTURE section 17](../ARCHITECTURE.md#17-model-router). Prices live only in the
  config file and feed the budget ledger; a price change is a config change.
- **Product routes use only Opus, Sonnet and Haiku** (`claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5`). The
  router has an allowlist of model ids and refuses others. Opus designs, writes checks and verifies; Sonnet builds and
  drafts; Haiku classifies and captions.
- **Claude Fable 5.2** (`claude-fable-5-2`) is a **dev-time** architect and reviewer model that agents working on this
  repo may use for architecture and review work. It is never a product route: per PR #42, Fable and Mythos models are
  excluded from Anthropic zero data retention ([OQ-19](../OPEN_QUESTIONS.md#oq-19-what-is-fable-52-and-should-it-shape-the-architecture)).
- **Runtime model steps** use an **owned Messages-API loop** (PR #42 A§9.2): tool-less, structured output against a
  schema, `stop_reason` checked first, adaptive thinking, no forced `tool_choice`. Lane separation: a model that reads
  untrusted content has no tools ([ADR 0026](0026-routine-artifact-contract.md)).
- **Builders** use the Claude Agent SDK (Claude Code headless) **only inside build sandboxes**, with the key added by
  the egress proxy outside the sandbox. Workers load the superpowers `test-driven-development` and
  `verification-before-completion` skills, garrytan/gstack QA and ship skills (MIT; vendored skill files keep their
  headers and are listed in `NOTICE`), and a tdd-guard-style hook.
- Escalation on refusal, cut-off or failed validation: Haiku → Sonnet → Opus. An item-level model step drops Sonnet →
  Haiku after 5 clean runs and goes back up on any edit, failure or refusal.
- **Local tier (optional, self-host)**: an OpenAI-compatible endpoint, `OFFLOAD_LOCAL_MODEL_URL`, served by exo
  (exo-explore/exo cluster) or Ollama, for `classify`, `caption` and `embed`; never `build` by default. Ported from
  PR #45 `models/local.ts`.
- **Budgets**: per build ($4.00 cap), per routine run (`limits.run_budget_usd`), per tenant per month (default in
  [OQ-05](../OPEN_QUESTIONS.md#oq-05-model-provider-terms-and-monthly-model-budget)). At 80% of the monthly budget,
  `caption` and `classify` move to the local tier if configured; at 100%, paid routes stop and the UI shows "needs you".
- BYOK: a tenant may supply its own Anthropic key (stored as a credential, used only through the broker).
- Embeddings: local embedder by default (`qwen3-embedding` class, 1024 dims) on the brain host, so no text leaves for
  embeddings.

## Consequences
- This ADR names no prices. Changing a model id is a config change plus a router allowlist update.
- The runtime has no Agent SDK dependency.

## Alternatives considered
- One model for everything: cost.
- Agent SDK for runtime model steps: brings file and shell tools that would then be denied one by one (PR #42 A§9.2).

## Sources
Old ADR 0008, 0009; old `brain/src/models/router.ts`; PR #42 A§9.2, A§12; PR #45 `models/local.ts`; obra/superpowers;
garrytan/gstack; exo-explore/exo.

## Revisions
- 2026-11-14: model ids and prices moved to config and ARCHITECTURE §17 ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P2, [design review A (2026-11-14)](../SOURCES.md#design-review-a), #106); Fable 5.2 is
  dev-time only, no price claim (owner fact, [design review B (2026-11-14)](../SOURCES.md#design-review-b), 24); owned Messages loop for runtime model steps ([design review C (2026-11-14)](../SOURCES.md#design-review-c), P0-2);
  gstack skills and exo attributed ([design review B (2026-11-14)](../SOURCES.md#design-review-b), 11).
