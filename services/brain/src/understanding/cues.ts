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
const HOST_RE = /(?<![\w@.-])(?:https?:\/\/)?((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+([a-z]{2,63}))(?![\w-])/gi;

export interface Cue {
  appBundleId?: string;
  appName?: string;
  host?: string;
}

function hostIn(text: string): { host: string; at: number } | null {
  for (const m of text.matchAll(HOST_RE)) {
    const tld = m[2]!.toLowerCase();
    if (CODE_SUFFIXES.has(tld)) continue;
    return { host: m[1]!.toLowerCase().replace(/^www\./, ""), at: m.index ?? 0 };
  }
  return null;
}

function appIn(text: string): { name: string; id: string; at: number } | null {
  let best: { name: string; id: string; at: number } | null = null;
  for (const [name, id] of KNOWN_APPS) {
    const re = new RegExp(`(?<![\\p{L}\\p{N}])${name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?![\\p{L}\\p{N}])`, "u");
    const m = re.exec(text);
    if (m !== null && (best === null || m.index < best.at)) best = { name, id, at: m.index };
  }
  return best;
}

/** The app and host one masked text snapshot shows: the earliest known app name (window chrome is at the top) and the
 * earliest host-shaped token (the URL bar). Pseudonym tokens are ignored. Empty when nothing is found. */
export function cueOf(text: string): Cue {
  const t = text.replace(TOKEN_RE, " ");
  const app = appIn(t);
  const host = hostIn(t);
  return {
    ...(app === null ? {} : { appBundleId: app.id, appName: NAME_OF.get(app.id) ?? app.name }),
    ...(host === null ? {} : { host: host.host }),
  };
}
