/**
 * Stable keyed pseudonyms (ADR 0028) and the router's per-run placeholders. Free text that reaches the cloud may
 * contain these tokens and no other `<kind:...>` token.
 */
export const PSEUDONYM_KINDS = ["person", "email", "phone", "doc"] as const;

/** One pseudonym, unanchored (embed it in a larger pattern). */
export const PSEUDONYM_RE = /<(person|email|phone|doc):h_[0-9a-f]{16}>/;
const PSEUDONYM_WHOLE = /^<(person|email|phone|doc):h_[0-9a-f]{16}>$/;
/** Router placeholders: `<person:qkzt.1>`, `<person:qkzt.1.first>`, `<person:qkzt.me>`. */
const PLACEHOLDER_WHOLE = /^<person:[a-z]{4}\.([0-9]+(\.first)?|me)>$/;
/** Anything shaped like a kind token. Deliberately wide: unknown shapes must be caught, not skipped. */
const ANGLE_TOKEN_RE = /<[A-Za-z_][A-Za-z0-9_]*:[^<>\s]*>/g;

export function isPseudonym(s: string): boolean {
  return PSEUDONYM_WHOLE.test(s);
}

/** Every `<kind:...>` token in `s` that is neither a pseudonym nor a router placeholder. */
export function disallowedTokens(s: string): string[] {
  return (s.match(ANGLE_TOKEN_RE) ?? []).filter((t) => !PSEUDONYM_WHOLE.test(t) && !PLACEHOLDER_WHOLE.test(t));
}

export function hasOnlyAllowedTokens(s: string): boolean {
  return disallowedTokens(s).length === 0;
}
