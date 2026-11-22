// Deterministic ids: the same observations give the same span and instance ids, so a re-run writes the same rows.
import { createHash } from "node:crypto";

/** A uuid-shaped id from sha256 of the parts (version nibble 8: custom, RFC 9562; variant 10). */
export function uuidFrom(...parts: readonly string[]): string {
  const h = createHash("sha256").update(parts.join("\u0000")).digest("hex");
  const v = ((parseInt(h[16]!, 16) & 0x3) | 0x8).toString(16);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-8${h.slice(13, 16)}-${v}${h.slice(17, 20)}-${h.slice(20, 32)}`;
}
