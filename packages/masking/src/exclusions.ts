import builtin from "./exclusions.builtin.json" with { type: "json" };

/**
 * Exclusions: windows Offload never watches (DATA_MODEL.md `exclusions`, ARCHITECTURE.md section 2 "Exclusions").
 * The built-in list is the same file the Mac bundles (m3-02); a member's own "Never watch" rows are added to it.
 */

export const EXCLUSION_KINDS = ["bundle_id", "host", "title_contains"] as const;
export type ExclusionKind = (typeof EXCLUSION_KINDS)[number];

export interface ExclusionRule {
  kind: ExclusionKind;
  value: string;
}

export const BUILTIN_EXCLUSIONS: readonly ExclusionRule[] = builtin as ExclusionRule[];

export interface ExclusionSubject {
  app_bundle_id?: string | undefined;
  host?: string | undefined;
  title?: string | undefined;
}

/**
 * The first rule the object matches, or null. `host`: exact or dot-suffix (`bank.example` matches
 * `www.bank.example`, not `notbank.example`), case-insensitive. `bundle_id`: exact. `title_contains`: case-insensitive
 * substring of the title.
 */
export function matchExclusion(rules: readonly ExclusionRule[], subject: ExclusionSubject): ExclusionRule | null {
  const host = subject.host?.toLowerCase();
  const title = subject.title?.toLowerCase();
  for (const rule of rules) {
    const value = rule.value.toLowerCase();
    if (value === "") continue;
    switch (rule.kind) {
      case "host":
        if (host !== undefined && (host === value || host.endsWith(`.${value}`))) return rule;
        break;
      case "bundle_id":
        if (subject.app_bundle_id !== undefined && subject.app_bundle_id === rule.value) return rule;
        break;
      case "title_contains":
        if (title !== undefined && title.includes(value)) return rule;
        break;
    }
  }
  return null;
}
