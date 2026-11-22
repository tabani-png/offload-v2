import { readFile } from "node:fs/promises";

/**
 * API configuration (m1-04). Names only here; values are read, never logged. Secrets are given as references and
 * resolved by resolveSecretRef, so the environment holds where a secret is, not the secret.
 */
export interface ApiConfig {
  /** OFFLOAD_PUBLIC_BASE_URL: the public origin, for example https://offload.example.com. */
  publicBaseUrl: string;
  /** OIDC login; absent when OFFLOAD_OIDC_ISSUER is unset (magic link only). */
  oidc?: { issuer: string; clientId: string; clientSecretRef: string };
  /** OFFLOAD_DEVICE_TOKEN_SIGNING_KEY_REF: reference to the ES256 (P-256) PKCS#8 PEM private key. */
  deviceTokenSigningKeyRef: string;
}

export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConfigError";
  }
}

const need = (env: Record<string, string | undefined>, name: string): string => {
  const v = env[name];
  if (v === undefined || v === "") throw new ConfigError(`${name} is required`);
  return v;
};

export function loadApiConfig(env: Record<string, string | undefined> = process.env): ApiConfig {
  const publicBaseUrl = need(env, "OFFLOAD_PUBLIC_BASE_URL").replace(/\/+$/, "");
  let u: URL;
  try {
    u = new URL(publicBaseUrl);
  } catch {
    throw new ConfigError("OFFLOAD_PUBLIC_BASE_URL must be a URL");
  }
  if (u.protocol !== "https:" || u.pathname !== "/" || u.search || u.hash) {
    throw new ConfigError("OFFLOAD_PUBLIC_BASE_URL must be an https origin (__Host- cookies need Secure)");
  }
  const cfg: ApiConfig = { publicBaseUrl, deviceTokenSigningKeyRef: need(env, "OFFLOAD_DEVICE_TOKEN_SIGNING_KEY_REF") };
  if (env["OFFLOAD_OIDC_ISSUER"]) {
    cfg.oidc = {
      issuer: need(env, "OFFLOAD_OIDC_ISSUER"),
      clientId: need(env, "OFFLOAD_OIDC_CLIENT_ID"),
      clientSecretRef: need(env, "OFFLOAD_OIDC_CLIENT_SECRET_REF"),
    };
  }
  return cfg;
}

/**
 * Resolves a secret reference: `file:<absolute path>` (a mounted secret) or `env:<NAME>` (a variable set by the
 * operator's secret manager). Errors name the reference kind, never the value.
 */
export async function resolveSecretRef(ref: string, env: Record<string, string | undefined> = process.env): Promise<string> {
  if (ref.startsWith("file:/")) {
    try {
      return (await readFile(ref.slice("file:".length), "utf8")).trim();
    } catch {
      throw new ConfigError("secret file reference could not be read");
    }
  }
  if (/^env:[A-Z][A-Z0-9_]{0,127}$/.test(ref)) {
    const v = env[ref.slice(4)];
    if (v === undefined || v === "") throw new ConfigError("secret env reference is not set");
    return v;
  }
  throw new ConfigError("secret references are file:<path> or env:<NAME>");
}
