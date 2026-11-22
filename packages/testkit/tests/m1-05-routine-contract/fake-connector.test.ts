import { expect, test } from "bun:test";
import { jcs, sha256Hex } from "@offload/contracts";
import { FakeConnectorError, fakeConnector, type FixtureSet, type ItemInput } from "../../src/index.ts";

// Synthetic fixture tokens (ADR 0027): `tok_` + 12 hex.
const SHEET = "tok_5ee7000000a1";
const PAYOUT_A = "tok_a0a0a0a0a0a1";
const PAYOUT_B = "tok_b0b0b0b0b0b2";
const CUSTOMER = "tok_c0ffee000003";

function payoutsFixture(): FixtureSet {
  return {
    reads: [
      {
        capability: "payments.payouts",
        args: { account: CUSTOMER, since: "2026-11-01", limit: 2 },
        output: {
          payouts: [
            { id: PAYOUT_A, amount: 1250, currency: "eur", status: "paid", arrival: "2026-11-03T08:00:00Z" },
            { id: PAYOUT_B, amount: 990, currency: "eur", status: "paid", arrival: "2026-11-05T08:00:00Z" },
          ],
        },
      },
      {
        capability: "sheet.rows",
        args: { account: CUSTOMER, since: "2026-11-01", limit: 2 },
        output: { rows: [] },
      },
    ],
    enum_values: ["eur", "paid"],
  };
}

test("FAKE: recorded reads are replayed by capability and args hash", async () => {
  const fake = fakeConnector(payoutsFixture());

  // Same args in a different key order hash to the same JCS bytes, so they match.
  const out = (await fake.read("payments.payouts", { limit: 2, since: "2026-11-01", account: CUSTOMER })) as {
    payouts: { id: string }[];
  };
  expect(out.payouts.map((p) => p.id)).toEqual([PAYOUT_A, PAYOUT_B]);

  // Same args under a different capability serve that capability's recording, not the other one.
  expect(await fake.read("sheet.rows", { account: CUSTOMER, since: "2026-11-01", limit: 2 })).toEqual({ rows: [] });

  // A capability with no recording does not match on args alone.
  await expect(fake.read("mail.messages", { account: CUSTOMER, since: "2026-11-01", limit: 2 })).rejects.toThrow(
    FakeConnectorError,
  );

  // Different args under a recorded capability do not match either.
  await expect(fake.read("payments.payouts", { account: CUSTOMER, since: "2026-11-01", limit: 3 })).rejects.toThrow(
    FakeConnectorError,
  );
});

test("FAKE: commit items are recorded and never executed", async () => {
  const realFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = (() => {
    fetchCalls++;
    throw new Error("fake connector test: network is not allowed");
  }) as unknown as typeof globalThis.fetch;
  try {
    await commitScenario(() => fetchCalls);
  } finally {
    globalThis.fetch = realFetch;
  }
});

async function commitScenario(fetchCalls: () => number): Promise<void> {
  const fake = fakeConnector(payoutsFixture());
  const items: ItemInput[] = [
    {
      item_key: PAYOUT_A,
      capability: "sheet.append",
      connection_ref: "conn_sheets",
      args: { sheet: SHEET, row: [PAYOUT_A, 1250, "eur"] },
    },
    {
      item_key: PAYOUT_B,
      capability: "sheet.append",
      connection_ref: "conn_sheets",
      args: { sheet: SHEET, row: [PAYOUT_B, 990, "eur"] },
    },
  ];
  const expectedHashes = items.map((i) =>
    sha256Hex(jcs({ capability: i.capability, connection_ref: i.connection_ref, args: i.args })),
  );

  const results = await fake.commit(items);

  expect(results).toEqual([
    { item_key: PAYOUT_A, item_hash: expectedHashes[0] as string, outcome: "recorded" },
    { item_key: PAYOUT_B, item_hash: expectedHashes[1] as string, outcome: "recorded" },
  ]);
  for (const h of expectedHashes) expect(h).toMatch(/^[0-9a-f]{64}$/);
  expect(fetchCalls()).toBe(0);

  // Recorded as deep copies: changing the caller's objects later does not change the record.
  (items[0] as ItemInput).args["row"] = ["changed"];
  const recorded = fake.items();
  expect(recorded.map((r) => r.item_hash)).toEqual(expectedHashes);
  expect(recorded[0]?.args).toEqual({ sheet: SHEET, row: [PAYOUT_A, 1250, "eur"] });
  expect(recorded[1]).toEqual({ ...(items[1] as ItemInput), item_hash: expectedHashes[1] as string });

  // Committing again appends; nothing is executed.
  await fake.commit([]);
  expect(fake.items()).toHaveLength(2);

  // An SDK Item that carries its item_hash is accepted when the hash is right.
  const withHash = { ...(items[1] as ItemInput), item_key: "tok_e0e0e0e0e0e4", item_hash: expectedHashes[1] as string };
  expect(await fake.commit([withHash])).toEqual([
    { item_key: "tok_e0e0e0e0e0e4", item_hash: expectedHashes[1] as string, outcome: "recorded" },
  ]);
  expect(fake.items()).toHaveLength(3);

  // A wrong item_hash is refused and nothing in that batch is recorded.
  const good = { ...(items[1] as ItemInput), item_key: "tok_f0f0f0f0f0f5" };
  const wrong = { ...withHash, item_key: "tok_f0f0f0f0f0f6", item_hash: expectedHashes[0] as string };
  let caught: unknown;
  try {
    await fake.commit([good, wrong]);
  } catch (e) {
    caught = e;
  }
  expect(caught).toBeInstanceOf(FakeConnectorError);
  expect((caught as FakeConnectorError).code).toBe("item_hash_mismatch");
  expect(fake.items()).toHaveLength(3);
  expect(fetchCalls()).toBe(0);
}

test("FAKE: a read with no recording fails the test", async () => {
  const fake = fakeConnector(payoutsFixture());
  const secretArg = "tok_dead00beef99";
  const args = { account: secretArg, since: "2026-10-01" };
  const hash = sha256Hex(jcs(args));

  let caught: unknown;
  try {
    await fake.read("payments.payouts", args);
  } catch (e) {
    caught = e;
  }
  expect(caught).toBeInstanceOf(FakeConnectorError);
  const err = caught as FakeConnectorError;
  expect(err.code).toBe("no_recording");
  expect(err.message).toContain("payments.payouts");
  expect(err.message).toContain(hash);
  // Privacy: the error names the args hash, never the arg values.
  expect(err.message).not.toContain(secretArg);
  expect(err.message).not.toContain("2026-10-01");

  // The fake remembers the miss, so the post-check fails even though the routine code swallowed the error above.
  expect(fake.missedReads()).toEqual([{ capability: "payments.payouts", args_hash: hash }]);
  let post: unknown;
  try {
    fake.assertNoMissedReads();
  } catch (e) {
    post = e;
  }
  expect(post).toBeInstanceOf(FakeConnectorError);
  expect((post as FakeConnectorError).code).toBe("missed_reads");
  expect((post as FakeConnectorError).message).toContain(hash);
  expect((post as FakeConnectorError).message).not.toContain(secretArg);

  // A fake with only matched reads passes the post-check.
  const clean = fakeConnector(payoutsFixture());
  await clean.read("sheet.rows", { account: CUSTOMER, since: "2026-11-01", limit: 2 });
  expect(() => clean.assertNoMissedReads()).not.toThrow();
});

test("FAKE: a fixture set with an untokenised string is refused", () => {
  const realName = "Jane Example";
  const refuse = (fixture: FixtureSet): FakeConnectorError => {
    try {
      fakeConnector(fixture);
    } catch (e) {
      expect(e).toBeInstanceOf(FakeConnectorError);
      return e as FakeConnectorError;
    }
    throw new Error("expected the fixture set to be refused");
  };

  // In a read's output, nested in an array.
  const inOutput = payoutsFixture();
  (inOutput.reads[1] as { output: unknown }).output = { rows: [{ name: realName }] };
  const e1 = refuse(inOutput);
  expect(e1.code).toBe("untokenised_value");
  // The error points at where the value is, never at the value itself.
  expect(e1.message).toContain("/rows/0/name");
  expect(e1.message).not.toContain(realName);

  // In a read's args.
  const inArgs = payoutsFixture();
  (inArgs.reads[0] as { args: Record<string, unknown> }).args["account"] = "acct_live_123";
  expect(refuse(inArgs).code).toBe("untokenised_value");

  // In an expected item's args.
  const inItems: FixtureSet = {
    ...payoutsFixture(),
    expected_items: [
      { item_key: PAYOUT_A, capability: "sheet.append", connection_ref: "conn_sheets", args: { row: [realName] } },
    ],
  };
  expect(refuse(inItems).code).toBe("untokenised_value");

  // A lower-case word that is not a listed enum value is refused too.
  const unlisted = payoutsFixture();
  unlisted.enum_values = ["eur"];
  expect(refuse(unlisted).code).toBe("untokenised_value");

  // Tokens, dates, numbers, booleans, null and listed enum values are accepted.
  const ok = payoutsFixture();
  ok.reads.push({
    capability: "calendar.events",
    args: { calendar: SHEET, from: "2026-11-01", to: "2026-11-02T00:00:00.000Z" },
    output: { events: [{ id: PAYOUT_A, all_day: false, minutes: 30, location: null, status: "paid" }] },
  });
  expect(() => fakeConnector(ok)).not.toThrow();
});

test("FAKE: replayed outputs are copies and a duplicate recording is refused", async () => {
  const fake = fakeConnector(payoutsFixture());
  const args = { account: CUSTOMER, since: "2026-11-01", limit: 2 };
  const first = (await fake.read("payments.payouts", args)) as { payouts: { amount: number }[] };
  (first.payouts[0] as { amount: number }).amount = 0;
  first.payouts.pop();
  const second = (await fake.read("payments.payouts", args)) as { payouts: { amount: number }[] };
  expect(second.payouts.map((p) => p.amount)).toEqual([1250, 990]);

  // Two recordings for the same (capability, args hash) are ambiguous, even with keys in another order.
  const dup = payoutsFixture();
  dup.reads.push({ capability: "sheet.rows", args: { limit: 2, since: "2026-11-01", account: CUSTOMER }, output: {} });
  let caught: unknown;
  try {
    fakeConnector(dup);
  } catch (e) {
    caught = e;
  }
  expect(caught).toBeInstanceOf(FakeConnectorError);
  expect((caught as FakeConnectorError).code).toBe("duplicate_recording");
});
