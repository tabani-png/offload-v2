# 0021. Model router and builder models

Status: accepted · Date: 2026-11-14 · Carries over old ADR 0009, 0008

## Context
Different jobs need different models. All model calls must be masked, budgeted and logged in one place.

## Decision
- One **model router** module in `services/brain` (shared by builder and runtime through a package export) is the only
  egress for model calls. It masks ([ADR 0005](0005-masked-text-only-reaches-models.md)), budgets, logs usage to
  `model_usage`, and escalates.
- Model ids are **configuration**, not code (deployment config `config/models.json` with env overrides), with these defaults (prices per million tokens,
  input/output, as of 2026-11-03):

  | Tier | Model id | Price | Routes |
  |---|---|---|---|
  | Opus 5.5 | `claude-opus-5-5` | $4 / $20 | `design` (fix brief), `check_write` (check set, held-out check), `verify`, `understand`, `explain` |
  | Sonnet 5.5 | `claude-sonnet-5-5` | $2 / $10 | `build` (workers), `draft`, `item_step` |
  | Haiku 5.5 | `claude-haiku-5-5` | $0.10 / $0.50 | `classify`, `caption`, `label`, proven item steps |
  | Local (optional) | Ollama or exo endpoint | $0 | `classify`, `caption`, `embed` for self-hosters; never `build` by default |

- Escalation on refusal, cut-off or failed validation: Haiku → Sonnet → Opus. An item step drops Sonnet → Haiku after
  5 clean runs and goes back up on any edit, failure or refusal.
- Server-side refusal fallbacks are enabled on Opus and Sonnet routes (`fallbacks: "default"`).
- **Builders** use the Claude Agent SDK (Claude Code headless) inside the sandbox, with the key injected by the egress
  proxy, never inside the sandbox. Workers load the superpowers TDD and verification skills and a tdd-guard-style hook.
- **Budgets**: per build ($4.00 cap, [ADR 0012](0012-builder-policy-one-worker-held-out-fan-out.md)), per routine run
  (from the routine policy), per tenant per month (default in [OQ-05](../OPEN_QUESTIONS.md#oq-05-model-provider-terms-and-monthly-model-budget)).
  At 80% of the monthly budget, `caption` and `classify` move to the local tier if configured; at 100%, paid routes stop
  and the UI shows "needs you".
- BYOK: a tenant may supply its own Anthropic key (stored in the credential vault).
- Embeddings: local embedder by default (`qwen3-embedding` class, 1024 dims) on the brain host, so no text leaves for
  embeddings.

## Consequences
- Prices are read from config to compute the budget ledger; a price change is a config change.
- "Fable 5.2" is not used by default; see [OQ-19](../OPEN_QUESTIONS.md#oq-19-what-is-fable-52-and-should-it-shape-the-architecture).

## Alternatives considered
- One model for everything: cost.

## Sources
Old ADR 0008, 0009; old `brain/src/models/router.ts`; Claude API model table (cached 2026-11-03).
