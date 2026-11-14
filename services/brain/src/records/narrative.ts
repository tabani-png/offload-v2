// The weekly sentence: model words, numbers checked by code (ADR 0003, harvested from PR #43 checkNarrative).
import type { CompleteText } from "../user-model/ports.ts";
import type { UserContext } from "../understanding/context.ts";
import type { WeekRecord } from "./week-record.ts";

/** A model-written text may only use numbers that are in the record. */
export function checkNarrative(_text: string, _record: unknown): { ok: boolean; unknown: string[] } {
  throw new Error("not implemented");
}
/** The code sentence for a week (used when no model sentence passes the check). */
export function weekSentence(_record: WeekRecord): string {
  throw new Error("not implemented");
}
/** The prompt for the weekly sentence. Goals appear only inside the <user_context> block. */
export function weekNarrativePrompt(_record: WeekRecord, _user: UserContext | undefined): string {
  throw new Error("not implemented");
}
export async function writeWeekSentence(
  _record: WeekRecord,
  _user: UserContext | undefined,
  _complete: CompleteText | null,
): Promise<{ sentence: string; source: "model" | "code" }> {
  throw new Error("not implemented");
}
