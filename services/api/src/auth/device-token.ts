import { createPrivateKey, createPublicKey, type KeyObject } from "node:crypto";
import { SignJWT, calculateJwkThumbprint, errors, exportJWK, jwtVerify } from "jose";
import { DeviceTokenClaimsSchema, type DeviceTokenAudience } from "@offload/contracts";
import type { Clock } from "../clock.ts";

/**
 * Device tokens (ADR 0014): ES256 JWT, 15 minutes, `aud` = the nonce's audience (`device` or `member`), claims
 * `tenant_id`, `member_id`, `device_id`. Signed by the key behind OFFLOAD_DEVICE_TOKEN_SIGNING_KEY_REF (PKCS#8 PEM,
 * P-256). A valid signature is not enough on use: the caller re-checks the device is not revoked.
 */

export const DEVICE_TOKEN_TTL_SECONDS = 15 * 60;

export interface DeviceTokenClaims {
  aud: DeviceTokenAudience;
  tenant_id: string;
  member_id: string;
  device_id: string;
  exp: number;
}

export type VerifyResult = { ok: true; claims: DeviceTokenClaims } | { ok: false; code: "unauthenticated" | "token_expired" };

export interface DeviceTokenIssuer {
  mint(c: { audience: DeviceTokenAudience; tenantId: string; memberId: string; deviceId: string }): Promise<{ token: string; expiresAt: Date }>;
  verify(token: string, audience: DeviceTokenAudience): Promise<VerifyResult>;
}

export function deviceTokenIssuer(opts: { pkcs8Pem: string; issuer: string; clock: Clock }): DeviceTokenIssuer {
  let keys: Promise<{ priv: KeyObject; pub: KeyObject; kid: string }> | null = null;
  const load = () =>
    (keys ??= (async () => {
      const priv = createPrivateKey(opts.pkcs8Pem);
      if (priv.asymmetricKeyType !== "ec" || priv.asymmetricKeyDetails?.namedCurve !== "prime256v1") {
        throw new Error("device token signing key must be an EC P-256 private key");
      }
      const pub = createPublicKey(priv);
      const kid = await calculateJwkThumbprint(await exportJWK(pub), "sha256");
      return { priv, pub, kid };
    })());

  return {
    async mint(c) {
      const { priv, kid } = await load();
      const iat = Math.floor(opts.clock.now().getTime() / 1000);
      const exp = iat + DEVICE_TOKEN_TTL_SECONDS;
      const token = await new SignJWT({ tenant_id: c.tenantId, member_id: c.memberId, device_id: c.deviceId })
        .setProtectedHeader({ alg: "ES256", typ: "JWT", kid })
        .setIssuer(opts.issuer).setAudience(c.audience).setSubject(c.deviceId)
        .setIssuedAt(iat).setExpirationTime(exp)
        .sign(priv);
      return { token, expiresAt: new Date(exp * 1000) };
    },
    async verify(token, audience) {
      const { pub } = await load();
      try {
        const { payload } = await jwtVerify(token, pub, {
          algorithms: ["ES256"], audience, issuer: opts.issuer, currentDate: opts.clock.now(), requiredClaims: ["exp", "iat"],
        });
        const claims = DeviceTokenClaimsSchema.safeParse(payload);
        if (!claims.success || claims.data.aud !== audience || claims.data.device_id !== payload.sub) return { ok: false, code: "unauthenticated" };
        return { ok: true, claims: claims.data };
      } catch (err) {
        return { ok: false, code: err instanceof errors.JWTExpired ? "token_expired" : "unauthenticated" };
      }
    },
  };
}
