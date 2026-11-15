import { generateKeyPairSync } from "node:crypto";
import { signerFromPem, type ServiceSigner } from "@offload/db";

/** An Ed25519 signer with a fresh keypair per call, plus the PEMs so tests can verify independently. */
export type FakeSigner = ServiceSigner & { pkcs8Pem: string; publicKeyPem: string };

export function fakeSigner(): FakeSigner {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const pkcs8Pem = privateKey.export({ format: "pem", type: "pkcs8" }).toString();
  const publicKeyPem = publicKey.export({ format: "pem", type: "spki" }).toString();
  return { ...signerFromPem(pkcs8Pem), pkcs8Pem, publicKeyPem };
}
