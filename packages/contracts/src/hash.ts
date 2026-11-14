import { sha256 } from "@noble/hashes/sha2.js";
import { bytesToHex, utf8ToBytes } from "@noble/hashes/utils.js";

/** Lowercase hex sha256 of UTF-8 text or raw bytes. Pure JS: runs in the browser and in Bun. */
export function sha256Hex(input: Uint8Array | string): string {
  return bytesToHex(sha256(typeof input === "string" ? utf8ToBytes(input) : input));
}
