export const UNTRUSTED_SYSTEM_NOTE = "";

export function untrusted(_source: string, _text: string): string {
  throw new Error("not implemented");
}

/** True when every untrusted tag in `text` is balanced and none escapes. */
export function untrustedTagsBalanced(_text: string): boolean {
  throw new Error("not implemented");
}
