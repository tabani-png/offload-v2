import type { Context } from "hono";
import type { ErrorCode } from "@offload/contracts";
import { ulid } from "@offload/db";

/** An error the API answers with the error envelope (docs/API.md "Error envelope"). Messages never hold values. */
export class ApiError extends Error {
  constructor(readonly status: 400 | 401 | 403 | 404 | 409 | 413 | 500, readonly code: ErrorCode, message: string) {
    super(message);
    this.name = "ApiError";
  }
}

export const invalidRequest = (message: string) => new ApiError(400, "invalid_request", message);
export const unauthenticated = (message = "not signed in") => new ApiError(401, "unauthenticated", message);
export const tokenExpired = (message = "expired") => new ApiError(401, "token_expired", message);

export function requestId(): string {
  return `req_${ulid()}`;
}

export function errorResponse(c: Context, err: ApiError): Response {
  return c.json({ error: { code: err.code, message: err.message, request_id: requestId() } }, err.status);
}

/** Anything that is not an ApiError is a 500 with no detail (the cause is never echoed). */
export function toApiError(err: unknown): ApiError {
  return err instanceof ApiError ? err : new ApiError(500, "server_error", "something went wrong");
}
