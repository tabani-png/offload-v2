// The <user_context> block (old brain/src/understanding/context.ts). Role, industry and goals from the profile are
// context only: sanitised, shown to a model inside this marked block, never used in arithmetic (ADR 0003).
export const USER_CONTEXT_MAX = 80;

export interface UserContext {
  role?: string;
  industry?: string;
  goals?: string[];
}

export function sanitizeUserContext(_v: unknown): UserContext | undefined {
  throw new Error("not implemented");
}
export function userContextBlock(_user: UserContext | undefined): string {
  throw new Error("not implemented");
}
