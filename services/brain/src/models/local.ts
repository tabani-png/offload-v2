/**
 * Local tier host check (ADR 0021; carried from PR #45 `models/local.ts` per MIGRATION 5.6, written fresh and widened
 * to private networks for exo clusters). Accepted: loopback (127.0.0.0/8, ::1, localhost) and private networks
 * (RFC 1918, fc00::/7). Hostnames other than `localhost` are refused: their address cannot be checked at load.
 */

export class LocalModelUrlError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "LocalModelUrlError";
  }
}

function ipv4(host: string): number[] | null {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (!m) return null;
  const parts = m.slice(1).map(Number);
  return parts.every((p) => p <= 255) ? parts : null;
}

function allowedIpv4([a, b]: number[]): boolean {
  if (a === 127) return true; // loopback
  if (a === 10) return true; // RFC 1918
  if (a === 172 && b! >= 16 && b! <= 31) return true; // RFC 1918
  if (a === 192 && b === 168) return true; // RFC 1918
  return false;
}

function allowedIpv6(host: string): boolean {
  const h = host.toLowerCase();
  if (h === "::1") return true;
  // fc00::/7: first byte fc or fd. URL serialisation drops leading zeros, so a fc/fd group has exactly 4 hex digits.
  return /^f[cd][0-9a-f]{2}:/.test(h);
}

/** Returns the URL when its host is loopback or a private network; throws LocalModelUrlError otherwise. */
export function parseLocalModelUrl(raw: string): URL {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new LocalModelUrlError("not a URL");
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") throw new LocalModelUrlError("scheme must be http or https");
  if (url.username !== "" || url.password !== "") throw new LocalModelUrlError("credentials in the URL are not allowed");
  const host = url.hostname;
  if (host === "localhost") return url;
  if (host.startsWith("[") && host.endsWith("]")) {
    if (allowedIpv6(host.slice(1, -1))) return url;
    throw new LocalModelUrlError("host is not loopback or a private network");
  }
  const v4 = ipv4(host);
  if (v4 && allowedIpv4(v4)) return url;
  throw new LocalModelUrlError("host is not loopback or a private network");
}
