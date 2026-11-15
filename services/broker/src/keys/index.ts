import type { KeyProvider } from "@offload/contracts/src/broker/index.ts";
import { awsKmsKeyProvider } from "./aws-kms.ts";
import { localKeyProvider } from "./local.ts";

export { awsKmsKeyProvider, localKeyProvider };
export { KeyFileError } from "./local.ts";

/** Builds the provider OFFLOAD_KEY_PROVIDER names. The AWS SDK is imported only when `aws-kms` is chosen. */
export async function loadKeyProvider(env: Record<string, string | undefined>): Promise<KeyProvider> {
  const which = env["OFFLOAD_KEY_PROVIDER"];
  if (which === "local") {
    const file = env["OFFLOAD_MASTER_KEY_FILE"];
    if (!file) throw new Error("OFFLOAD_MASTER_KEY_FILE is required for the local key provider");
    return localKeyProvider(file);
  }
  if (which === "aws-kms") {
    const ref = env["OFFLOAD_KMS_KEY_REF"];
    if (!ref) throw new Error("OFFLOAD_KMS_KEY_REF is required for the aws-kms key provider");
    const { awsKmsClient } = await import("./aws-kms-client.ts");
    return awsKmsKeyProvider(awsKmsClient(), ref);
  }
  throw new Error("OFFLOAD_KEY_PROVIDER must be local or aws-kms");
}
