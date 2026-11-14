/**
 * Transform isolate (spike S7, ADR 0026). Stub: implementation follows the red tests.
 */

export type TransformErrorCode = "transform_timeout" | "transform_memory" | "transform_error" | "transform_invalid";

export class TransformError extends Error {
  readonly code: TransformErrorCode;
  constructor(code: TransformErrorCode, message: string) {
    super(message);
    this.name = "TransformError";
    this.code = code;
  }
}

export async function runTransform(_source: string, _input: unknown): Promise<unknown> {
  throw new Error("not implemented");
}

export async function loadTransform(_source: string): Promise<void> {
  throw new Error("not implemented");
}
