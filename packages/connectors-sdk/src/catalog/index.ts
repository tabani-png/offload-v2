import {
  type Adapter,
  type CatalogEntry,
  CatalogEntrySchema,
  type CatalogMethod,
} from "@offload/contracts/src/connections/index.ts";
import { findCapability } from "../capabilities.ts";
import launchData from "./launch.json" with { type: "json" };

/**
 * The launch catalog as data (ADR 0033). Every entry ships unverified (`s5_verified_at: null`); spike S5 sets the
 * date in launch.json in a separate commit reviewed by the owner. Only verified entries are offered.
 */

export class CatalogLoadError extends Error {
  readonly code = "catalog_invalid";
  constructor(message: string) {
    super(message);
    this.name = "CatalogLoadError";
  }
}

const METHOD_ADAPTER: Record<CatalogMethod, Adapter> = {
  google_internal: "openapi",
  composio: "composio",
  mcp: "mcp",
  openapi: "openapi",
};

/** The adapter a catalog method connects through. */
export function methodAdapter(method: CatalogMethod): Adapter {
  return METHOD_ADAPTER[method];
}

/** Validates catalog data. Throws CatalogLoadError on the first problem. */
export function loadCatalog(data: unknown): CatalogEntry[] {
  if (!Array.isArray(data)) throw new CatalogLoadError("catalog is not an array");
  const seen = new Set<string>();
  const out: CatalogEntry[] = [];
  for (const [i, item] of data.entries()) {
    const parsed = CatalogEntrySchema.safeParse(item);
    if (!parsed.success) throw new CatalogLoadError(`catalog entry ${i} is not a valid CatalogEntry`);
    const entry = parsed.data;
    if (seen.has(entry.provider)) throw new CatalogLoadError(`duplicate provider ${entry.provider}`);
    seen.add(entry.provider);
    if (methodAdapter(entry.method) !== entry.adapter) {
      throw new CatalogLoadError(`provider ${entry.provider}: method ${entry.method} needs adapter ${methodAdapter(entry.method)}`);
    }
    for (const cap of entry.capabilities) {
      if (!findCapability(cap)) throw new CatalogLoadError(`provider ${entry.provider}: unknown capability ${cap}`);
    }
    out.push(entry);
  }
  return out;
}

const LAUNCH: readonly CatalogEntry[] = loadCatalog(launchData);

/** A fresh deep copy of the validated launch catalog. */
export function launchCatalog(): CatalogEntry[] {
  return structuredClone(LAUNCH as CatalogEntry[]);
}

/** Entries spike S5 verified; the only ones a connection may be created for. */
export function availableEntries(catalog: readonly CatalogEntry[]): CatalogEntry[] {
  return catalog.filter((e) => e.s5_verified_at !== null);
}

export function findEntry(catalog: readonly CatalogEntry[], provider: string): CatalogEntry | undefined {
  return catalog.find((e) => e.provider === provider);
}
