import { z } from "zod";

/** RFC 3339 date-time with a mandatory offset (`Z` or `±hh:mm`). */
export const rfc3339 = z.iso.datetime({ offset: true });
/** Object ids on the device are ULIDs: 26 Crockford base32 characters. */
export const ulid = z.string().regex(/^[0-7][0-9A-HJKMNP-TV-Z]{25}$/);
export const uuid = z.uuid();
export const hex64 = z.string().regex(/^[0-9a-f]{64}$/);
export const hex16 = z.string().regex(/^[0-9a-f]{16}$/);
const nonNegInt = z.number().int().min(0).max(Number.MAX_SAFE_INTEGER);
export const nonNegativeInt = nonNegInt;
