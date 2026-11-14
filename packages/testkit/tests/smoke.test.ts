import { expect, test } from "bun:test";

test("smoke: @offload/testkit exports the real-Postgres tenant fixture and commit fault injection", async () => {
  const mod = await import("../src/index.ts");
  for (const name of ["pgTenantFixture", "seedTenantRows", "freshDatabase", "onBeforeCommit", "roleUrl"]) {
    expect(typeof (mod as Record<string, unknown>)[name]).toBe("function");
  }
});
