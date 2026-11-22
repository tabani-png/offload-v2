import { z } from "zod";
import allowlistJson from "../../config/model-allowlist.json";
import modelsJson from "../../config/models.json";
import { LocalModelUrlError, parseLocalModelUrl } from "./local.ts";
import { PAID_TIERS, type PaidTier } from "./types.ts";

/**
 * Model router configuration (ADR 0021): `services/brain/config/models.json`, validated by zod at load. Model ids and
 * prices are configuration; prices are committed as null and filled by the owner or operator in a reviewed change.
 * The only env override is OFFLOAD_LOCAL_MODEL_URL (the optional local tier).
 */

export interface TierConfig {
  id: string;
  usd_per_mtok_in: number | null;
  usd_per_mtok_out: number | null;
  usd_per_mtok_cache_read: number | null;
}

export interface ModelsConfig {
  tiers: Record<PaidTier, TierConfig>;
  routes: Record<string, PaidTier>;
  local_routes: string[];
  local_model: string;
  max_usd_per_call: Record<string, number>;
  /** Present only when OFFLOAD_LOCAL_MODEL_URL is set and its host is loopback or a private network. */
  local?: { url: string; model: string };
  /** Model ids the router may send to (`config/model-allowlist.json`). */
  allowlist: string[];
}

export class ModelsConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ModelsConfigError";
  }
}

/** Routes the local tier never serves, whatever the config says. */
export const NEVER_LOCAL_ROUTES: readonly string[] = ["build"];

const ROUTE_RE = /^[a-z][a-z0-9_]{0,63}$/;
const price = z.number().nonnegative().finite().nullable();
const tier = z.strictObject({ id: z.string().min(1), usd_per_mtok_in: price, usd_per_mtok_out: price, usd_per_mtok_cache_read: price });
const tierName = z.enum(PAID_TIERS);

const modelsSchema = z.strictObject({
  tiers: z.strictObject({ opus: tier, sonnet: tier, haiku: tier }),
  routes: z.record(z.string().regex(ROUTE_RE), tierName),
  local_routes: z.array(z.string().regex(ROUTE_RE)),
  local_model: z.string().min(1).max(128),
  max_usd_per_call: z.record(z.string().regex(ROUTE_RE), z.number().positive().finite()),
});

const allowlistSchema = z.array(z.string().min(1)).min(1);

export const ALLOWED_MODEL_IDS: readonly string[] = Object.freeze(allowlistSchema.parse(allowlistJson));

export function loadModelsConfig(raw: unknown, env: Record<string, string | undefined> = {}, allowlist: readonly string[] = ALLOWED_MODEL_IDS): ModelsConfig {
  const parsed = modelsSchema.safeParse(raw);
  if (!parsed.success) throw new ModelsConfigError(`models.json invalid: ${parsed.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; ")}`);
  const c = parsed.data;
  for (const t of PAID_TIERS) {
    if (!allowlist.includes(c.tiers[t].id)) throw new ModelsConfigError(`tier ${t}: model id is not on the router allowlist`);
  }
  for (const r of c.local_routes) {
    if (NEVER_LOCAL_ROUTES.includes(r)) throw new ModelsConfigError(`local_routes: the local tier never serves ${r}`);
  }
  const config: ModelsConfig = {
    tiers: c.tiers,
    routes: c.routes,
    local_routes: c.local_routes,
    local_model: c.local_model,
    max_usd_per_call: c.max_usd_per_call,
    allowlist: [...allowlist],
  };
  const url = env["OFFLOAD_LOCAL_MODEL_URL"];
  if (url !== undefined && url !== "") {
    try {
      config.local = { url: parseLocalModelUrl(url).toString(), model: c.local_model };
    } catch (e) {
      if (e instanceof LocalModelUrlError) throw new ModelsConfigError(`OFFLOAD_LOCAL_MODEL_URL refused: ${e.message}`);
      throw e;
    }
  }
  return config;
}

/** The committed config, with the composition root's env (only OFFLOAD_LOCAL_MODEL_URL is read). */
export function loadDefaultModelsConfig(env: Record<string, string | undefined> = {}): ModelsConfig {
  return loadModelsConfig(modelsJson, env);
}
