import { z } from "zod";
import { sha256Hex } from "./hash.ts";
import { jcs } from "./jcs.ts";
import { rfc3339 } from "./primitives.ts";

export const FigureEvidenceSchema = z.strictObject({ kind: z.string().min(1).max(64), id: z.string().min(1).max(128) });

const figureFields = {
  value: z.number(),
  unit: z.string().min(1).max(64),
  arithmetic: z.string().min(1).max(512),
  evidence: z.array(FigureEvidenceSchema),
  /** Required, nullable: null until the raw evidence passes its TTL. */
  source_purged_at: rfc3339.nullable(),
};

export type FigureBody = z.infer<z.ZodObject<typeof figureFields>>;

/** `fig_` + first 16 hex of sha256(JCS(figure without id)). */
export function figureId(body: FigureBody): string {
  return `fig_${sha256Hex(jcs(body)).slice(0, 16)}`;
}

export function makeFigure(body: FigureBody): Figure {
  return { id: figureId(body), ...body };
}

export const FigureSchema = z
  .strictObject({ id: z.string().regex(/^fig_[0-9a-f]{16}$/), ...figureFields })
  .refine(({ id, ...body }) => id === figureId(body), { message: "id is not fig_ + 16 hex of sha256(JCS(figure without id))", path: ["id"] });

export type Figure = z.infer<typeof FigureSchema>;
