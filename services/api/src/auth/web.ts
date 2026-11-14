/**
 * Browser-facing helpers: the session and login cookies (ADR 0014) and the `return_to` rule.
 */

export const SESSION_COOKIE = "__Host-offload_session";
export const LOGIN_COOKIE = "__Host-offload_login";

/** 12 hours absolute. */
export const SESSION_ABSOLUTE_MS = 12 * 60 * 60_000;
/** Idle timeout on the web: 30 minutes for owner and admin, 8 hours otherwise. The Mac UI uses device tokens. */
export function idleTimeoutMs(role: string): number {
  return role === "owner" || role === "admin" ? 30 * 60_000 : 8 * 60 * 60_000;
}
/** The login round trip (state, nonce, PKCE verifier, return_to) lives 10 minutes. */
export const LOGIN_TTL_MS = 10 * 60_000;
export const MAGIC_LINK_TTL_MS = 15 * 60_000;

/** `__Host-` cookies: Secure, Path=/, no Domain (the browser enforces it); httpOnly and SameSite=Lax as well. */
export function hostCookie(name: string, value: string, maxAgeSeconds: number): string {
  return `${name}=${value}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${maxAgeSeconds}`;
}

export function clearCookie(name: string): string {
  return hostCookie(name, "", 0);
}

/** The value of cookie `name` in a Cookie header, or undefined. */
export function readCookie(header: string | undefined | null, name: string): string | undefined {
  if (!header) return undefined;
  for (const part of header.split(";")) {
    const i = part.indexOf("=");
    if (i < 0) continue;
    if (part.slice(0, i).trim() === name) return part.slice(i + 1).trim();
  }
  return undefined;
}

/**
 * `return_to` must be a same-origin path: starts with one `/`, no scheme, no `//`, no backslash, no control
 * characters, and resolves to the public origin. Returns the path, "/" when absent, or null when refused.
 */
export function safeReturnTo(v: string | undefined | null, publicBaseUrl: string): string | null {
  if (v === undefined || v === null || v === "") return "/";
  if (v.length > 2048 || !v.startsWith("/") || v.startsWith("//") || v.includes("\\")) return null;
  if (/[\u0000-\u001f\u007f]/.test(v)) return null;
  try {
    const base = new URL(publicBaseUrl);
    return new URL(v, base).origin === base.origin ? v : null;
  } catch {
    return null;
  }
}

export interface LoginState {
  state: string;
  nonce: string;
  verifier: string;
  return_to: string;
  /** ms since epoch */
  exp: number;
}

export function encodeLoginState(s: LoginState): string {
  return Buffer.from(JSON.stringify(s)).toString("base64url");
}

export function decodeLoginState(v: string | undefined): LoginState | null {
  if (!v || !/^[A-Za-z0-9_-]{1,4096}$/.test(v)) return null;
  try {
    const s = JSON.parse(Buffer.from(v, "base64url").toString("utf8")) as LoginState;
    const strs = [s.state, s.nonce, s.verifier, s.return_to];
    if (strs.some((x) => typeof x !== "string" || x.length === 0) || typeof s.exp !== "number") return null;
    return s;
  } catch {
    return null;
  }
}

/** `redirect_uri` for device enrollment: exactly http://127.0.0.1:<port>/callback with port 1024..65535. */
export function isLoopbackRedirect(uri: string): boolean {
  const m = /^http:\/\/127\.0\.0\.1:([1-9][0-9]{3,4})\/callback$/.exec(uri);
  if (!m) return false;
  const port = Number(m[1]);
  return port >= 1024 && port <= 65535;
}
