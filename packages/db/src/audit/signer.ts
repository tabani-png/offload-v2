import { createHash, createPrivateKey, createPublicKey, sign as edSign, verify as edVerify, type KeyObject } from "node:crypto";
import { readFileSync } from "node:fs";

/**
 * The service signer port (ADR 0018). Ed25519 through node:crypto. The private key lives in memory only inside the
 * closure: it is never logged and never written to a row. A KMS-held key is a later slice behind this same port.
 */
export interface ServiceSigner {
  keyId: string;
  sign(bytes: Uint8Array): Uint8Array;
  verify(bytes: Uint8Array, sig: Uint8Array, keyId: string): boolean;
}

/** First 16 hex characters of sha256 of the 32-byte raw Ed25519 public key. */
export function keyIdOf(publicKey: KeyObject): string {
  const x = publicKey.export({ format: "jwk" }).x;
  if (typeof x !== "string") throw new Error("signing key is not an Ed25519 public key");
  return createHash("sha256").update(Buffer.from(x, "base64url")).digest("hex").slice(0, 16);
}

/** A signer from an Ed25519 PKCS#8 PEM. Throws without echoing any of the key text. */
export function signerFromPem(pkcs8Pem: string): ServiceSigner {
  let priv: KeyObject;
  try {
    priv = createPrivateKey(pkcs8Pem);
  } catch {
    throw new Error("the service signing key is not a valid PKCS#8 PEM");
  }
  if (priv.asymmetricKeyType !== "ed25519") throw new Error("the service signing key must be Ed25519");
  const pub = createPublicKey(priv);
  const keyId = keyIdOf(pub);
  return {
    keyId,
    sign: (bytes) => new Uint8Array(edSign(null, bytes, priv)),
    verify: (bytes, sig, id) => id === keyId && edVerify(null, bytes, pub, sig),
  };
}

/** Production signer: reads the PEM from the path in OFFLOAD_SERVICE_SIGNING_KEY_REF (passed in as `ref`). */
export function fileSigner(ref: string): ServiceSigner {
  let pem: string;
  try {
    pem = readFileSync(ref, "utf8");
  } catch {
    throw new Error("the service signing key file cannot be read");
  }
  return signerFromPem(pem);
}
