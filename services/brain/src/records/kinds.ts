// Kinds of work (ported from old brain/src/time/kinds.ts): from the app bundle id and host only, never content.
// v2 has no URL path (the Mac sends a `<doc:h_…>` pseudonym), so docs.google.com counts as docs: sheets and docs
// there cannot be told apart (DESIGN.md, known gaps).
export const WORK_KINDS = ["code", "docs", "meeting", "sheet", "email", "chat", "browse", "other"] as const;
export type WorkKind = (typeof WORK_KINDS)[number];

const BROWSERS = new Set(["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser"]);

const APP_KIND: Readonly<Record<string, WorkKind>> = {
  "com.apple.Terminal": "code",
  "com.googlecode.iterm2": "code",
  "com.mitchellh.ghostty": "code",
  "dev.warp.Warp-Stable": "code",
  "com.microsoft.VSCode": "code",
  "com.todesktop.230313mzl4w4u92": "code", // Cursor
  "dev.zed.Zed": "code",
  "com.apple.dt.Xcode": "code",
  "notion.id": "docs",
  "com.apple.iWork.Pages": "docs",
  "com.microsoft.Word": "docs",
  "com.microsoft.Excel": "sheet",
  "com.apple.iWork.Numbers": "sheet",
  "us.zoom.xos": "meeting",
  "com.microsoft.teams": "meeting",
  "com.microsoft.teams2": "meeting",
  "com.apple.iCal": "meeting",
  "com.apple.FaceTime": "meeting",
  "com.apple.mail": "email",
  "com.microsoft.Outlook": "email",
  "com.superhuman.electron": "email",
  "com.tinyspeck.slackmacgap": "chat",
  "com.apple.MobileSMS": "chat",
  "com.hnc.Discord": "chat",
};

const HOST_KIND: Readonly<Record<string, WorkKind>> = {
  "docs.google.com": "docs",
  "www.notion.so": "docs",
  "notion.so": "docs",
  "meet.google.com": "meeting",
  "zoom.us": "meeting",
  "app.zoom.us": "meeting",
  "teams.microsoft.com": "meeting",
  "calendar.google.com": "meeting",
  "mail.google.com": "email",
  "outlook.office.com": "email",
  "outlook.live.com": "email",
  "app.superhuman.com": "email",
  "app.slack.com": "chat",
  "discord.com": "chat",
};

export function kindOf(span: { appBundleId: string; host: string }): WorkKind {
  const byApp = APP_KIND[span.appBundleId];
  if (byApp !== undefined) return byApp;
  const host = span.host.toLowerCase();
  const byHost = HOST_KIND[host];
  if (byHost !== undefined) return byHost;
  if (host !== "" || BROWSERS.has(span.appBundleId)) return "browse";
  return "other";
}

/** Which kinds of work each onboarding drain is about (a ranking prior for weeks 1 to 4, and drain drift). */
export const DRAIN_KINDS: Readonly<Record<string, readonly WorkKind[]>> = {
  email: ["email"],
  meetings: ["meeting"],
  agent_babysitting: ["code"],
  reporting: ["sheet", "docs"],
  content: ["browse"],
  admin: ["other"],
  context_switching: [],
};
