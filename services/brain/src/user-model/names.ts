// Names stored in the user model are masked verb-object names. Understanding masks them upstream; this is the second
// line: it strips what must never be stored (emails, URLs, pseudonym tokens, digits). Replaced by the
// packages/masking leak scanner when it lands.

const URL_RE = /\b(?:https?:\/\/|www\.)\S+/gi;
const EMAIL_RE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
const TOKEN_RE = /<[^<>]*>/g;
const EDGE_RE = /^[\s:·,;#/|()[\]-]+|[\s:·,;#/|()[\]-]+$/g;
export const MAX_NAME = 80;

/** A storable task or episode name: no email, URL, `<…>` token or digit; one line; at most 80 characters. */
export function safeName(s: string): string {
  return s
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .replace(URL_RE, " ")
    .replace(EMAIL_RE, " ")
    .replace(TOKEN_RE, " ")
    .replace(/[<>@]/g, " ")
    .replace(/[0-9]/g, " ")
    .replace(/\s+/g, " ")
    .replace(EDGE_RE, "")
    .slice(0, MAX_NAME)
    .replace(EDGE_RE, "");
}

/** The stored name of a task: its scrubbed name, else words from its kind (`chat.reply` -> `chat reply`). */
export function taskName(name: string, kind: string): string {
  const n = safeName(name);
  if (n !== "") return n;
  const k = safeName(kind.replace(/[._-]+/g, " "));
  return k === "" ? "Untitled task" : k;
}

/** Lowercase words of 3+ letters, unique and sorted (for name Jaccard). */
export function nameWords(name: string): string[] {
  return [...new Set(safeName(name).toLowerCase().split(/[^a-z]+/).filter((w) => w.length >= 3))].sort();
}

/** True when the text holds an email address or a URL. */
export function hasLeak(text: string): boolean {
  // A bare host (`www.notion.so`) is allowed C1 metadata; a URL with a scheme or a path is not.
  return /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/.test(text) || /\bhttps?:\/\//i.test(text) || /\bwww\.[^\s/"]+\/[^\s"]/i.test(text);
}
