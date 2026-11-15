/**
 * Test client for the broker socket: JSON over HTTP on a Unix socket with the service token. Returns status and parsed
 * body (or the raw text when it is not JSON). The real BrokerPort client is wired in m2-04.
 */
export interface BrokerReply {
  status: number;
  json: any;
  text: string;
}

export function brokerClient(socketPath: string, token: string | null) {
  return async (path: string, body?: unknown, headers: Record<string, string> = {}): Promise<BrokerReply> => {
    const h: Record<string, string> = { "content-type": "application/json", ...headers };
    if (token !== null) h["authorization"] = `Bearer ${token}`;
    const res = await fetch(`http://broker${path}`, { method: "POST", headers: h, body: JSON.stringify(body ?? {}), unix: socketPath } as RequestInit);
    const text = await res.text();
    let json: unknown = null;
    try {
      json = JSON.parse(text);
    } catch {
      /* not JSON */
    }
    return { status: res.status, json, text };
  };
}
