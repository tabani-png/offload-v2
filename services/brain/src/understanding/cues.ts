// App and host cues for stand-in apps (CUE). The recordings import (m3-05) names the app from the macOS menu bar; a
// recording without one gets `recording.unknown` / "Screen" (screenwatch rows without app fields `screenwatch.screen`).
// Its masked text still shows window chrome ("Google Chrome") and the URL bar (the masker keeps the host only), so
// understanding reads the app and host from there. Rules only: a fixed table of app names, host-shaped tokens.

/** Stand-in app ids the Mac import emits when nothing names the app. */
const STAND_IN_IDS = new Set(["recording.unknown", "screenwatch.screen"]);

export function isStandInApp(bundleId: string, appName: string): boolean {
  if (STAND_IN_IDS.has(bundleId)) return true;
  return (bundleId.startsWith("recording.") || bundleId.startsWith("screenwatch.")) && appName === "Screen";
}

/** App names as window chrome shows them, with their bundle ids. Longest first so "Microsoft Excel" wins over "Excel". */
const KNOWN_APPS: ReadonlyArray<readonly [string, string]> = ([
  ["Google Chrome", "com.google.Chrome"], ["Safari", "com.apple.Safari"], ["Firefox", "org.mozilla.firefox"], ["Microsoft Edge", "com.microsoft.edgemac"],
  ["Brave Browser", "com.brave.Browser"], ["Arc", "company.thebrowser.Browser"], ["Mail", "com.apple.mail"], ["Microsoft Outlook", "com.microsoft.Outlook"],
  ["Outlook", "com.microsoft.Outlook"], ["Microsoft Excel", "com.microsoft.Excel"], ["Excel", "com.microsoft.Excel"], ["Numbers", "com.apple.iWork.Numbers"],
  ["Microsoft Word", "com.microsoft.Word"], ["Pages", "com.apple.iWork.Pages"], ["Keynote", "com.apple.iWork.Keynote"], ["Microsoft PowerPoint", "com.microsoft.Powerpoint"],
  ["Slack", "com.tinyspeck.slackmacgap"], ["Notion", "notion.id"], ["Zoom", "us.zoom.xos"], ["Microsoft Teams", "com.microsoft.teams2"], ["Finder", "com.apple.finder"],
  ["Preview", "com.apple.Preview"], ["Terminal", "com.apple.Terminal"], ["Visual Studio Code", "com.microsoft.VSCode"], ["Xcode", "com.apple.dt.Xcode"],
  ["Figma", "com.figma.Desktop"], ["Superhuman", "com.superhuman.electron"],
] as const).slice().sort((a, b) => b[0].length - a[0].length);

/** Display name for a known bundle id (the first, longest name). */
const NAME_OF = new Map<string, string>();
for (const [name, id] of [...KNOWN_APPS].sort((a, b) => b[0].length - a[0].length)) if (!NAME_OF.has(id)) NAME_OF.set(id, name);

/** File and language suffixes: `README.md`, `billing.ts` or `Node.js` look like hosts but are not. */
const CODE_SUFFIXES = new Set([
  "js", "ts", "jsx", "tsx", "mjs", "cjs", "py", "rb", "go", "rs", "md", "sh", "cs", "cpp", "hpp", "swift", "kt", "java", "json", "yaml", "yml",
  "toml", "txt", "csv", "pdf", "docx", "xlsx", "pptx", "html", "css", "sql", "vue", "php", "dart", "png", "jpg", "jpeg", "gif", "mov", "mp4", "zip", "log",
]);
const TOKEN_RE = /<[^<>]*>/g;
/** Lowercase as read (a URL bar shows hosts in lowercase; "Mr.Smith" or "update.Regards" never match). */
const HOST_RE = /(?<![\w@.-])(https?:\/\/|www\.)?((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+([a-z]{2,63}))(?![\w-])/g;
/** Top-level domains a host without a scheme or `www.` must end in (plus the reserved `example` and `test`). A fixed
 * list: OCR joins words with a period ("e.g.invoices", "j.r.smith", "v2.final.draft"), and those never end in one. */
const COMMON_TLDS = new Set(
  ("com net org edu gov mil int io co app dev ai us uk de fr es it nl ca au in jp br ch se no dk fi pl be at ie nz sg hk eu info biz me " +
    "tv xyz cloud so cc ly gg sh to fm site online tech store shop page example test").split(" "),
);

export interface Cue {
  appBundleId?: string;
  appName?: string;
  host?: string;
}

/** The host a URL bar shows. OCR often drops the space after a period ("Thanks for the update.Regards", "Mr.Smith"),
 * so a host-shaped token counts only when it looks like a URL bar: lowercase as read, and either after a scheme or
 * `www.`, or on a chrome line (the first CHROME_LINES lines) ending in a known top-level domain with no one-character
 * label before it. */
function hostIn(text: string): { host: string } | null {
  const chrome = text.split(/\r?\n/).slice(0, CHROME_LINES).join("\n").length;
  for (const m of text.matchAll(HOST_RE)) {
    const tld = m[3]!;
    if (CODE_SUFFIXES.has(tld) || /^\d+$/.test(m[2]!.split(".")[0]!)) continue;
    const prefixed = m[1] !== undefined;
    const onChrome = (m.index ?? 0) < chrome;
    // Initials or an abbreviation before the last label ("j.r.smith", "e.g.invoices") are not a host; one short label
    // alone ("x.com") can be.
    const before = m[2]!.split(".").slice(0, -1);
    const shortLabel = before.length >= 2 && before.some((l) => l.length === 1);
    if (prefixed || (onChrome && COMMON_TLDS.has(tld) && !shortLabel)) {
      const host = m[1] === "www." ? m[2]! : m[2]!.replace(/^www\./, "");
      return { host };
    }
  }
  return null;
}

/** One RegExp per known app, built once: the name at the start of a line, as a whole word. */
const APP_RES: ReadonlyArray<{ name: string; id: string; re: RegExp }> = KNOWN_APPS.map(([name, id]) => ({
  name, id, re: new RegExp(`^${name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?![\\p{L}\\p{N}])`, "u"),
}));
/** Window chrome is at the top of a snapshot: only its first lines can name the app. */
export const CHROME_LINES = 2;

/** The app named at the start of one of the first CHROME_LINES lines (window chrome), never one in the body text:
 * "ask the Slack admin" or "a recipe from Mail" name no app. Longest name first ("Microsoft Excel" over "Excel"). */
function appIn(text: string): { name: string; id: string } | null {
  for (const line of text.split(/\r?\n/).slice(0, CHROME_LINES)) {
    const l = line.trimStart();
    for (const a of APP_RES) if (a.re.test(l)) return { name: a.name, id: a.id };
  }
  return null;
}

/** The app and host one masked text snapshot shows: a known app name opening one of its first lines (window chrome)
 * and the earliest host-shaped token (the URL bar). Pseudonym tokens are ignored. Empty when nothing is found. */
export function cueOf(text: string): Cue {
  const t = text.replace(TOKEN_RE, " ");
  const app = appIn(t);
  const host = hostIn(t);
  return {
    ...(app === null ? {} : { appBundleId: app.id, appName: NAME_OF.get(app.id) ?? app.name }),
    ...(host === null ? {} : { host: host.host }),
  };
}
