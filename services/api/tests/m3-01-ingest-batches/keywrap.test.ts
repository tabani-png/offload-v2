import { afterAll, beforeAll, expect, test } from "bun:test";
import { errorCode, makeHarness, type Harness } from "./harness.ts";

let h: Harness;
beforeAll(async () => {
  h = await makeHarness();
});
afterAll(async () => {
  await h?.close();
});

// Opaque ciphertext stand-ins: the server stores whatever base64url text it is given and never interprets it.
const wrapped = (label: string) => `v1.${Buffer.from(`ciphertext-${label}`).toString("base64url")}`;
const wrapUrl = (id: string) => `/v1/devices/${id}/pseudonym-key-wrap`;

test("KEYWRAP: a device stores and reads back only its own wrapped key", async () => {
  const first = await h.device(h.fx.a, h.fx.a.owner);
  const second = await h.device(h.fx.a, h.fx.a.owner);
  const t1 = await h.token(first, "device");
  const t2 = await h.token(second, "device");

  // Nothing yet, and no recovery copy in the tenant either.
  const empty = await h.req(wrapUrl(first.deviceId), { bearer: t1 });
  expect(empty.status).toBe(200);
  expect(await empty.json()).toEqual({ recovery_wrap: null });

  // The first device stores its wrap and the scrypt-wrapped recovery copy.
  const put1 = await h.req(wrapUrl(first.deviceId), {
    method: "PUT", bearer: t1,
    json: { wrapped_key: wrapped("first"), wrapped_by_device_id: null, method: "recovery_code", recovery_wrap: wrapped("recovery") },
  });
  expect(put1.status).toBe(204);
  const get1 = await h.req(wrapUrl(first.deviceId), { bearer: t1 });
  expect(await get1.json()).toEqual({ wrapped_key: wrapped("first"), wrapped_by_device_id: null, method: "recovery_code" });

  // A new device with no wrap yet gets the recovery copy only.
  const fresh = await h.req(wrapUrl(second.deviceId), { bearer: t2 });
  expect(await fresh.json()).toEqual({ recovery_wrap: wrapped("recovery") });

  // It then stores a wrap made by the first device; a recovery_wrap from a later device is refused.
  const bad = await h.req(wrapUrl(second.deviceId), {
    method: "PUT", bearer: t2,
    json: { wrapped_key: wrapped("second"), wrapped_by_device_id: first.deviceId, method: "device", recovery_wrap: wrapped("other") },
  });
  expect(bad.status).toBe(400);
  expect(await errorCode(bad)).toBe("invalid_request");
  const put2 = await h.req(wrapUrl(second.deviceId), {
    method: "PUT", bearer: t2, json: { wrapped_key: wrapped("second"), wrapped_by_device_id: first.deviceId, method: "device" },
  });
  expect(put2.status).toBe(204);
  expect(await (await h.req(wrapUrl(second.deviceId), { bearer: t2 })).json())
    .toEqual({ wrapped_key: wrapped("second"), wrapped_by_device_id: first.deviceId, method: "device" });
  // The first device's row did not change.
  expect(await (await h.req(wrapUrl(first.deviceId), { bearer: t1 })).json())
    .toEqual({ wrapped_key: wrapped("first"), wrapped_by_device_id: null, method: "recovery_code" });

  // Shape checks: method and wrapper must agree; junk is refused; a member token is not a device token.
  for (const body of [
    { wrapped_key: wrapped("x"), wrapped_by_device_id: null, method: "device" },
    { wrapped_key: wrapped("x"), wrapped_by_device_id: first.deviceId, method: "recovery_code" },
    { wrapped_key: "", wrapped_by_device_id: null, method: "recovery_code" },
    { wrapped_key: wrapped("x"), wrapped_by_device_id: null, method: "plain" },
    { wrapped_key: wrapped("x"), wrapped_by_device_id: null, method: "recovery_code", extra: 1 },
  ]) {
    const res = await h.req(wrapUrl(second.deviceId), { method: "PUT", bearer: t2, json: body });
    expect({ body, status: res.status }).toEqual({ body, status: 400 });
  }
  const member = await h.req(wrapUrl(second.deviceId), { bearer: await h.token(second, "member") });
  expect(member.status).toBe(401);
  const stored = (await h.fx.admin.query("select wrapped_key, recovery_wrap from pseudonym_key_wraps where device_id = $1", [first.deviceId])).rows[0];
  expect(stored).toEqual({ wrapped_key: wrapped("first"), recovery_wrap: wrapped("recovery") });
});

test("KEYWRAP: another device's wrap is 404", async () => {
  const mine = await h.device(h.fx.a, h.fx.a.owner);
  const sibling = await h.device(h.fx.a, h.fx.a.member);
  const foreign = await h.device(h.fx.b, h.fx.b.owner);
  for (const dev of [mine, sibling, foreign]) {
    const res = await h.req(wrapUrl(dev.deviceId), {
      method: "PUT", bearer: await h.token(dev, "device"),
      json: { wrapped_key: wrapped(dev.deviceId.slice(0, 8)), wrapped_by_device_id: null, method: "recovery_code" },
    });
    expect(res.status).toBe(204);
  }
  const t = await h.token(mine, "device");
  for (const other of [sibling, foreign]) {
    const read = await h.req(wrapUrl(other.deviceId), { bearer: t });
    expect({ id: other.deviceId, status: read.status }).toEqual({ id: other.deviceId, status: 404 });
    const text = await read.text();
    expect((JSON.parse(text) as { error: { code: string } }).error.code).toBe("not_found");
    expect(text).not.toContain("ciphertext");
    const write = await h.req(wrapUrl(other.deviceId), {
      method: "PUT", bearer: t, json: { wrapped_key: wrapped("hijack"), wrapped_by_device_id: null, method: "recovery_code" },
    });
    expect(write.status).toBe(404);
  }
  const untouched = (await h.fx.admin.query("select wrapped_key from pseudonym_key_wraps where device_id = $1", [foreign.deviceId])).rows[0].wrapped_key;
  expect(untouched).toBe(wrapped(foreign.deviceId.slice(0, 8)));
  expect((await h.req(wrapUrl("not-a-uuid"), { bearer: t })).status).toBe(404);
});
