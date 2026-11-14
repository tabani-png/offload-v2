// Names stored in the user model are masked verb-object names. Understanding masks them upstream; this is the second
// line: it strips what must never be stored (emails, URLs, pseudonym tokens, digits). Replaced by the
// packages/masking leak scanner when it lands.

/** A storable task or episode name: no email, URL, `<…>` token or digit; one line; at most 80 characters. */
export function safeName(_s: string): string {
  throw new Error("not implemented");
}
/** Lowercase words of 3+ letters, unique and sorted (for name Jaccard). */
export function nameWords(_name: string): string[] {
  throw new Error("not implemented");
}
/** True when the text holds an email address or a URL. */
export function hasLeak(_text: string): boolean {
  throw new Error("not implemented");
}
