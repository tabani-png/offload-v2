// Names stored in the user model are masked verb-object names. Understanding masks them upstream; this is the second
// line: it strips what must never be stored (emails, URLs, pseudonym tokens, digits). Replaced by the
// packages/masking leak scanner when it lands.

const URL_RE = /\b(?:https?:\/\/|www\.)\S+/gi;
const EMAIL_RE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
/** A host with a path and no scheme: `github.com/acme/repo/pull`. A bare host is allowed C1 metadata. */
const BARE_LINK_RE = /\b(?:[a-z0-9-]+\.)+[a-z]{2,}\/\S*/gi;
const TOKEN_RE = /<[^<>]*>/g;
const EDGE_RE = /^[\s:·,;#/|()[\]-]+|[\s:·,;#/|()[\]-]+$/g;
export const MAX_NAME = 80;

/** A storable task or episode name: no email, URL, `<…>` token or digit; one line; at most 80 characters. */
export function safeName(s: string): string {
  return s
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .replace(URL_RE, " ")
    .replace(BARE_LINK_RE, " ")
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

/** File and language suffixes: `README.md` or `Node.js` look like host names but are not links. */
const CODE_SUFFIXES = new Set([
  "js", "ts", "jsx", "tsx", "mjs", "cjs", "py", "rb", "go", "rs", "md", "sh", "cs", "cpp", "hpp", "swift", "kt", "java",
  "json", "yaml", "yml", "toml", "txt", "csv", "pdf", "docx", "xlsx", "pptx", "html", "css", "sql", "vue", "php", "dart",
]);
/** A dotted token whose last label has 2 or more letters: `acme.com`, `bit.ly`, `shop.example`. */
const HOST_TOKEN_RE = /\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.([a-z]{2,})\b/gi;

/** Stricter than hasLeak, for text a person types or a model writes (goals, role, industry, the weekly sentence):
 * also refuses `www.` and any host name, whatever its suffix. Code file names (`README.md`, `Node.js`) are fine. */
export function hasLink(text: string): boolean {
  if (hasLeak(text) || /\bwww\./i.test(text)) return true;
  for (const m of text.matchAll(HOST_TOKEN_RE)) if (!CODE_SUFFIXES.has(m[1]!.toLowerCase())) return true;
  return false;
}

/** True when the text holds an email address or a URL. */
export function hasLeak(text: string): boolean {
  // A bare host (`www.notion.so`) is allowed C1 metadata; a URL with a scheme or a path is not.
  return /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/.test(text) || /\bhttps?:\/\//i.test(text) || /\b(?:[a-z0-9-]+\.)+[a-z]{2,}\/[^\s"]/i.test(text);
}
