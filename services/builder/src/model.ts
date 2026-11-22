// ModelPort: the builder's view of W1-F's model router (ADR 0021), the only egress for product model calls. The router
// masks, budgets and logs; the builder names a route and gets text. Tests use a fake; never a real model.
export type ModelRoute = "check_write";
export interface ModelRequest {
  route: ModelRoute;
  system: string;
  prompt: string;
  max_tokens: number;
}
export interface ModelPort {
  complete(r: ModelRequest): Promise<{ text: string; model: string }>;
}
