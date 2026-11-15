import { expect, test } from "bun:test";
import { IngestEnvelopeSchema, UPLOAD_KINDS } from "../../src/index.ts";
import { envelope, focus, keyframeMeta, noticeAck, reviewEvent, stepResult } from "./fixtures.ts";

test("KIND: the five upload kinds are accepted", () => {
  expect([...UPLOAD_KINDS]).toEqual(["observation_batch", "review_event", "notice_ack", "keyframe", "step_result"]);
  const objects: Record<string, unknown> = {
    observation_batch: focus, review_event: reviewEvent, notice_ack: noticeAck, keyframe: keyframeMeta, step_result: stepResult,
  };
  for (const kind of UPLOAD_KINDS) {
    expect(IngestEnvelopeSchema.safeParse(envelope(kind, [objects[kind]])).success).toBe(true);
  }
  // envelope.kind selects the object schema: another kind's object is not accepted
  expect(IngestEnvelopeSchema.safeParse(envelope("review_event", [focus])).success).toBe(false);
  expect(IngestEnvelopeSchema.safeParse(envelope("observation_batch", [reviewEvent])).success).toBe(false);
  expect(IngestEnvelopeSchema.safeParse(envelope("keyframe", [stepResult])).success).toBe(false);
  // the envelope itself is strict
  expect(IngestEnvelopeSchema.safeParse(envelope("notice_ack", [noticeAck], { v: 2 })).success).toBe(false);
  expect(IngestEnvelopeSchema.safeParse(envelope("notice_ack", [noticeAck], { seq: -1 })).success).toBe(false);
  expect(IngestEnvelopeSchema.safeParse(envelope("notice_ack", [noticeAck], { sent_at: "2026-11-14T16:05:00" })).success).toBe(false);
  expect(IngestEnvelopeSchema.safeParse(envelope("notice_ack", [noticeAck], { sent_at: "2026-11-14T21:05:00Z" })).success).toBe(true);
});

test("KIND: run_outcome, baseline_sample and daily_aggregate are rejected", () => {
  for (const kind of ["run_outcome", "baseline_sample", "daily_aggregate", "", "OBSERVATION_BATCH", "observation"]) {
    expect(IngestEnvelopeSchema.safeParse(envelope(kind, [focus])).success).toBe(false);
  }
  for (const kind of ["run_outcome", "baseline_sample", "daily_aggregate"]) expect(UPLOAD_KINDS).not.toContain(kind);
});
