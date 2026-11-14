export class LocalModelUrlError extends Error {}

/** Returns the URL when its host is loopback or a private network; throws LocalModelUrlError otherwise. */
export function parseLocalModelUrl(_url: string): URL {
  throw new Error("not implemented");
}
