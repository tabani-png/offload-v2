// Kinds of work (ported from old brain/src/time/kinds.ts): from the app bundle id and host only, never content.
export const WORK_KINDS = ["code", "docs", "meeting", "sheet", "email", "chat", "browse", "other"] as const;
export type WorkKind = (typeof WORK_KINDS)[number];

export function kindOf(_span: { appBundleId: string; host: string }): WorkKind {
  throw new Error("not implemented");
}
