import {
  FakeModelProvider,
  InMemoryBudgetLedger,
  fakeClock,
  fakeLeakScanner,
  recordingAudit,
  recordingLog,
  type FakeModelProviderOptions,
} from "@offload/testkit/src/models/index.ts";
import rawModels from "../../config/models.json";
import { loadModelsConfig, type ModelsConfig } from "../../src/models/config.ts";
import type { RouteCall, RouterDeps } from "../../src/models/router.ts";

/** Synthetic test prices (USD per million tokens). Not real prices: no doc or test states a provider price. */
export const TEST_PRICES = {
  haiku: { in: 1, out: 10, cache: 0.1 },
  sonnet: { in: 2, out: 20, cache: 0.2 },
  opus: { in: 4, out: 40, cache: 0.4 },
} as const;

/** The committed models.json with synthetic prices filled in. */
export function pricedRaw(): Record<string, unknown> {
  const raw = structuredClone(rawModels) as { tiers: Record<string, Record<string, unknown>> } & Record<string, unknown>;
  for (const [tier, p] of Object.entries(TEST_PRICES)) {
    raw.tiers[tier]!["usd_per_mtok_in"] = p.in;
    raw.tiers[tier]!["usd_per_mtok_out"] = p.out;
    raw.tiers[tier]!["usd_per_mtok_cache_read"] = p.cache;
  }
  return raw;
}

export function pricedConfig(env: Record<string, string | undefined> = {}): ModelsConfig {
  return loadModelsConfig(pricedRaw(), env);
}

export interface Harness {
  provider: FakeModelProvider;
  ledger: InMemoryBudgetLedger;
  audit: ReturnType<typeof recordingAudit>;
  log: ReturnType<typeof recordingLog>;
  clock: ReturnType<typeof fakeClock>;
  deps: RouterDeps;
}

export function harness(opts: { provider?: FakeModelProviderOptions; config?: ModelsConfig; ledger?: InMemoryBudgetLedger } = {}): Harness {
  const provider = new FakeModelProvider(opts.provider);
  const ledger = opts.ledger ?? new InMemoryBudgetLedger();
  const audit = recordingAudit();
  const log = recordingLog();
  const clock = fakeClock();
  const deps: RouterDeps = {
    provider,
    ledger,
    scanner: fakeLeakScanner(),
    audit,
    clock,
    config: opts.config ?? pricedConfig(),
    log: (line) => log.log(line),
  };
  return { provider, ledger, audit, log, clock, deps };
}

export const TENANT = "t_01HZZTESTTENANT0000000001";

export function call(over: Partial<RouteCall> = {}): RouteCall {
  return {
    tenant_id: TENANT,
    route: "classify",
    system: "Classify the task.",
    messages: [{ role: "user", content: "Sort these expense lines." }],
    max_tokens: 200,
    ...over,
  };
}

export const LABEL_SCHEMA = {
  type: "object",
  properties: { label: { type: "string", enum: ["low", "medium", "high"] } },
  required: ["label"],
  additionalProperties: false,
} as const;
