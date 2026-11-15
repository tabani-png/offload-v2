import { BrokerError } from "../errors.ts";

/**
 * The broker's host allowlist per provider (SECURITY_PRIVACY section 9). A request whose host is not listed for the
 * connection's provider is refused with `host_not_allowed` before any credential is decrypted.
 */

export interface OAuthConfig {
  authorizeUrl: string;
  tokenUrl: string;
  /** Returns `{ sub, email }` for the access token: the account label and the account hash come from it. */
  userinfoUrl: string;
  clientId: string;
  /** Read from the file OFFLOAD_GOOGLE_CLIENT_SECRET_REF names; never leaves the broker. */
  clientSecret: string;
  /** Tests only: the endpoints are loopback http. */
  allowHttp?: boolean;
  extraAuthorizeParams?: Record<string, string>;
}

export interface ProviderConfig {
  /** `host` or `host:port`, lower case. */
  hosts: readonly string[];
  /** Tests only: allow `http:` for these hosts. Production entries are https only. */
  allowHttp?: boolean;
  /** How the credential is presented to the upstream. */
  auth: { header: string; scheme: "bearer" | "raw" };
  oauth?: OAuthConfig;
  /** MCP servers: the endpoint that answers JSON-RPC `tools/list`. */
  mcpToolsUrl?: string;
  /** Other providers: a GET endpoint listing tools; the response is `{ tools: [...] }` or an array. */
  toolsUrl?: string;
}

export type ProviderTable = Record<string, ProviderConfig>;

export interface ComposioConfig {
  apiKey: string;
  hosts: readonly string[];
  allowHttp?: boolean;
}

const BEARER = { header: "authorization", scheme: "bearer" } as const;

const GOOGLE_AUTH = "https://accounts.google.com/o/oauth2/v2/auth";
const GOOGLE_TOKEN = "https://oauth2.googleapis.com/token";
const GOOGLE_USERINFO = "https://openidconnect.googleapis.com/v1/userinfo";

/** The launch catalog's providers (m2-02). Google comes with the owner's Internal OAuth client (operator item O5). */
export function defaultProviders(google: { clientId: string; clientSecret: string } | null): ProviderTable {
  const googleOAuth = google
    ? {
        oauth: {
          authorizeUrl: GOOGLE_AUTH, tokenUrl: GOOGLE_TOKEN, userinfoUrl: GOOGLE_USERINFO, clientId: google.clientId,
          clientSecret: google.clientSecret, extraAuthorizeParams: { access_type: "offline", prompt: "consent", include_granted_scopes: "true" },
        },
      }
    : {};
  return {
    gmail: { hosts: ["gmail.googleapis.com", "www.googleapis.com"], auth: BEARER, ...googleOAuth },
    google_calendar: { hosts: ["www.googleapis.com"], auth: BEARER, ...googleOAuth },
    google_sheets: { hosts: ["sheets.googleapis.com"], auth: BEARER, ...googleOAuth },
    google_drive: { hosts: ["www.googleapis.com", "drive.googleapis.com"], auth: BEARER, ...googleOAuth },
    stripe: { hosts: ["api.stripe.com"], auth: BEARER },
    notion: { hosts: ["mcp.notion.com"], auth: BEARER, mcpToolsUrl: "https://mcp.notion.com/mcp" },
    linear: { hosts: ["mcp.linear.app"], auth: BEARER, mcpToolsUrl: "https://mcp.linear.app/mcp" },
  };
}

export const DEFAULT_COMPOSIO_HOSTS = ["backend.composio.dev"] as const;

/**
 * Checks `url` against `hosts` and returns the parsed URL. The scheme must be https (http only when `allowHttp`),
 * there must be no userinfo, and the host (with port, if any) must equal an entry exactly.
 */
export function checkHost(url: string, hosts: readonly string[], allowHttp: boolean | undefined): URL {
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    throw new BrokerError("invalid_request", "request url is not a valid url");
  }
  const schemeOk = u.protocol === "https:" || (allowHttp === true && u.protocol === "http:");
  if (!schemeOk || u.username !== "" || u.password !== "" || !hosts.includes(u.host.toLowerCase())) {
    throw new BrokerError("host_not_allowed", "the request host is not on the provider's allowlist");
  }
  return u;
}
