import { expect, test } from "bun:test";
import { randomBytes } from "node:crypto";
import { uuidv7 } from "@offload/db";
import { awsKmsKeyProvider } from "../../src/keys/aws-kms.ts";
import { awsKmsClient } from "../../src/keys/aws-kms-client.ts";

// Not a red-test tag and not counted toward min_tests. Runs only when the operator has set up the KMS key (operator item
// O7) and AWS credentials are present; presence is checked as a boolean and never printed.
const haveKey = Boolean(process.env["OFFLOAD_KMS_KEY_REF"]);
const haveCredentials = Boolean(process.env["AWS_ACCESS_KEY_ID"] || process.env["AWS_PROFILE"] || process.env["AWS_WEB_IDENTITY_TOKEN_FILE"] || process.env["AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"]);

test.skipIf(!haveKey || !haveCredentials)("LIVE: aws-kms wraps and unwraps a data key with the configured key", async () => {
  const provider = awsKmsKeyProvider(awsKmsClient(), process.env["OFFLOAD_KMS_KEY_REF"]!);
  const tenant = uuidv7();
  const dek = randomBytes(32);
  const wrapped = await provider.wrap(dek, { tenant_id: tenant });
  expect(Buffer.from(await provider.unwrap(wrapped, { tenant_id: tenant })).equals(dek)).toBe(true);
  await expect(provider.unwrap(wrapped, { tenant_id: uuidv7() })).rejects.toThrow();
});
