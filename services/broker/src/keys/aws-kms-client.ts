import { DecryptCommand, GenerateDataKeyCommand, KMSClient } from "@aws-sdk/client-kms";
import type { KmsClient } from "@offload/contracts/src/broker/index.ts";

/**
 * The production KmsClient over @aws-sdk/client-kms. The one place the SDK is imported. Credentials come from the
 * workload identity of the broker's pod or host (never from this repo). Not exercised by the slice suite, which uses
 * FakeKms; the `LIVE:` test runs it against the real key.
 */
export function awsKmsClient(region: string | undefined = process.env["AWS_REGION"]): KmsClient {
  const kms = new KMSClient(region ? { region } : {});
  return {
    async generateDataKey({ keyId, encryptionContext }) {
      const r = await kms.send(new GenerateDataKeyCommand({ KeyId: keyId, KeySpec: "AES_256", EncryptionContext: encryptionContext }));
      if (!r.Plaintext || !r.CiphertextBlob) throw new Error("kms: GenerateDataKey returned no key");
      return { plaintext: r.Plaintext, ciphertextBlob: r.CiphertextBlob };
    },
    async decrypt({ keyId, ciphertextBlob, encryptionContext }) {
      const r = await kms.send(new DecryptCommand({ KeyId: keyId, CiphertextBlob: ciphertextBlob, EncryptionContext: encryptionContext }));
      if (!r.Plaintext) throw new Error("kms: Decrypt returned no key");
      return { plaintext: r.Plaintext };
    },
  };
}
