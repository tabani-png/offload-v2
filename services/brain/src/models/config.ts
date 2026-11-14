import type { PaidTier } from "./types.ts";

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
  /** Present only when OFFLOAD_LOCAL_MODEL_URL is set and accepted. */
  local?: { url: string; model: string };
  allowlist: string[];
}

export class ModelsConfigError extends Error {}

export const ALLOWED_MODEL_IDS: readonly string[] = [];

export function loadModelsConfig(_raw: unknown, _env: Record<string, string | undefined> = {}): ModelsConfig {
  throw new Error("not implemented");
}

export function loadDefaultModelsConfig(_env: Record<string, string | undefined> = {}): ModelsConfig {
  throw new Error("not implemented");
}
