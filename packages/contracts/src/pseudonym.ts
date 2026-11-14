/**
 * Stable keyed pseudonyms (ADR 0028) and the router's per-run placeholders. Free text that reaches the cloud may
 * contain these tokens and no other `<kind:...>` token.
 */
export const PSEUDONYM_KINDS = ["person", "email", "phone", "doc"] as const;

/** One pseudonym, unanchored (embed it in a larger pattern). */
export const PSEUDONYM_RE = /<(person|email|phone|doc):h_[0-9a-f]{16}>/;
const PSEUDONYM_WHOLE = /^<(person|email|phone|doc):h_[0-9a-f]{16}>$/;
/** Anything with a colon between angle brackets. Deliberately wide: unknown shapes must be caught, not skipped. */
const ANGLE_TOKEN_RE = /<[^<>]*:[^<>]*>/g;
/** Pseudonyms and router placeholders (`<person:qkzt.1>`, `<person:qkzt.1.first>`, `<person:qkzt.me>`). */
const ALLOWED_TOKEN_RE = /<(?:(?:person|email|phone|doc):h_[0-9a-f]{16}|person:[a-z]{4}\.(?:[0-9]+(?:\.first)?|me))>/g;

export function isPseudonym(s: string): boolean {
  return PSEUDONYM_WHOLE.test(s);
}

/**
 * Every `<kind:...>` token left in `s` once pseudonyms and router placeholders are removed. The text is NFKC
 * normalised first so full-width brackets cannot hide a token; removing allowed tokens first catches nesting.
 */
export function disallowedTokens(s: string): string[] {
  return s.normalize("NFKC").replace(ALLOWED_TOKEN_RE, "").match(ANGLE_TOKEN_RE) ?? [];
}

export function hasOnlyAllowedTokens(s: string): boolean {
  return disallowedTokens(s).length === 0;
}
