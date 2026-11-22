// Synthetic fixtures for the m1-02 contract tests. Nothing here is real data.
import { sha256Hex } from "../../src/index.ts";

export const DEVICE_ID = "0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a33";
export const IMPORT_ID = "0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a44";
export const RUN_ID = "0193a6f2-6c1e-7b51-9d2a-5f0e8c1b2a55";
export const ULID_A = "01JCZ3X5Q8M2N4P6R8T0V1W2Y3";
export const ULID_B = "01JCZ3X5Q8M2N4P6R8T0V1W2Y4";
export const TS = "2026-11-14T16:01:12-05:00";

export function obs(kind: string, extra: Record<string, unknown> = {}): Record<string, unknown> {
  return { id: ULID_A, ts: TS, kind, ...extra };
}

export const focus = obs("focus", {
  app_bundle_id: "com.example.Browser",
  app_name: "Example Browser",
  title: "Finance 2026 - Sheets",
  host: "docs.example.com",
  doc: "<doc:h_7c1e09b2a4d35f6e>",
});

export function snapshot(text: string, extra: Record<string, unknown> = {}): Record<string, unknown> {
  return obs("text_snapshot", {
    app_bundle_id: "com.example.Mail",
    text,
    text_hash: sha256Hex(text),
    text_source: "ax",
    ...extra,
  });
}

/** One valid observation per kind. */
export const validByKind: Record<string, Record<string, unknown>> = {
  focus,
  idle_start: obs("idle_start"),
  idle_end: obs("idle_end"),
  input_counts: obs("input_counts", { keys: 120, clicks: 14 }),
  text_snapshot: snapshot("Reply to <person:h_0123456789abcdef> about the invoice"),
  pause: obs("pause", { reason: "user" }),
  resume: obs("resume", { reason: "lock" }),
  permission_change: obs("permission_change", { perm: { screen_recording: true, accessibility: false } }),
};

export function envelope(kind: string, objects: unknown[], extra: Record<string, unknown> = {}): Record<string, unknown> {
  return { v: 1, device_id: DEVICE_ID, seq: 1842, sent_at: "2026-11-14T16:05:00-05:00", kind, objects, ...extra };
}

export const reviewEvent = {
  id: ULID_A, ts: TS, run_id: RUN_ID, review_seconds: 30, edit_seconds: 5, fix_seconds: 0, items_edited: 2,
  decision: "approved_with_edits", surface: "mac",
};
export const noticeAck = { id: ULID_A, ts: TS, notice_id: RUN_ID, notice_version: "2026-11" };
export const keyframeMeta = {
  id: ULID_A, ts: TS, phash: "0123456789abcdef", width: 1280, height: 800, bytes: 200000, sha256: sha256Hex("frame"),
};
export const stepResult = {
  id: ULID_A, ts: TS, command_id: RUN_ID, item_hash: sha256Hex("item"), outcome: "sent",
  detail_code: "ok", finished_at: "2026-11-14T16:01:20-05:00",
};
