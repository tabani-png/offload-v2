// Provider choice (OFFLOAD_SANDBOX_PROVIDER) and the Offload Cloud provider stub. e2b (Firecracker microVMs, ADR 0011)
// is built in m2-08; until then it fails as an infrastructure error, so a build ends infra_failed and bills nothing.
// apple-container and sandbox-exec are not providers in v2 (MIGRATION 5.6).
import { DockerProvider, type Executor } from "./docker.ts";
import { SandboxInfraError, type SandboxProvider } from "./provider.ts";

export function cloudProvider(): SandboxProvider {
  const down = async (): Promise<never> => {
    throw new SandboxInfraError("the e2b sandbox provider is not built yet (m2-08)");
  };
  return { name: "e2b", create: down, putFiles: down, getFiles: down, exec: down, snapshot: down, destroy: async () => {}, list: async () => [] };
}

export function sandboxProviderFromEnv(env: Readonly<Record<string, string | undefined>>, o: { executor?: Executor } = {}): SandboxProvider {
  const name = (env["OFFLOAD_SANDBOX_PROVIDER"] ?? "docker").trim();
  if (name === "docker") return new DockerProvider(o.executor === undefined ? {} : { executor: o.executor });
  if (name === "e2b") return cloudProvider();
  throw new Error(`unknown sandbox provider ${JSON.stringify(name)} (docker or e2b)`);
}
