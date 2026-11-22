/**
 * Fake connector (m1-05-routine-contract, ADR 0026, ADR 0027).
 * Serves recorded reads keyed by (capability, args hash), records commit items without executing them, and fails the
 * test on any read it has no recording for. Fixture values are fixture tokens (`tok_` + 12 hex); the only strings that
 * stay as they are: ISO dates, and enum values the fixture set lists in `enum_values`. Errors name capabilities,
 * hashes and JSON pointers, never connector values.
 */
import { jcs, sha256Hex } from "@offload/contracts";
import { itemHash, type Item } from "@offload/routine-sdk";

export type { Item };
export { itemHash };

/** A commit item as a caller hands it over: the SDK's Item, with `item_hash` optional (checked when present). */
export type ItemInput = Omit<Item, "item_hash"> & { item_hash?: string };

/** One recorded read from fixture capture: what the capability returned for these args. */
export type FixtureRead = {
  capability: string;
  args: Record<string, unknown>;
  output: unknown;
};

/**
 * A fixture: the recorded reads plus the expected commit items (ADR 0027), in token space.
 * `enum_values` lists the enum strings the brief's checks need kept as they are (lower-case identifiers only).
 */
export type FixtureSet = {
  reads: FixtureRead[];
  expected_items?: ItemInput[];
  enum_values?: string[];
};

/** A commit item as the fake recorded it. */
export type RecordedItem = Item;

export type CommitResult = { item_key: string; item_hash: string; outcome: "recorded" };

/** A read the fake had no recording for. Never holds the arg values, only their hash. */
export type MissedRead = { capability: string; args_hash: string };

export type FakeConnectorErrorCode =
  | "no_recording"
  | "missed_reads"
  | "untokenised_value"
  | "duplicate_recording"
  | "invalid_fixture"
  | "item_hash_mismatch";

export class FakeConnectorError extends Error {
  readonly code: FakeConnectorErrorCode;
  constructor(code: FakeConnectorErrorCode, message: string) {
    super(message);
    this.name = "FakeConnectorError";
    this.code = code;
  }
}

export interface FakeConnector {
  /** Replays the recorded output for (capability, args hash) as a deep copy; throws `no_recording` otherwise. */
  read(capability: string, args: Record<string, unknown>): Promise<unknown>;
  /**
   * Records the items (deep copies) with their item_hash. Never executes anything. A supplied `item_hash` must match
   * (`item_hash_mismatch` otherwise); the batch is checked whole before any item is recorded.
   */
  commit(items: readonly ItemInput[]): Promise<CommitResult[]>;
  /** Every item committed so far, in order (deep copies). */
  items(): RecordedItem[];
  /** Every read that had no recording, in order. */
  missedReads(): MissedRead[];
  /** Throws `missed_reads` if any read had no recording, even when the caller swallowed the read's error. */
  assertNoMissedReads(): void;
}

const FIXTURE_TOKEN = /^tok_[0-9a-f]{12}$/;
const ISO_DATE = /^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2}(\.\d{1,9})?)?(Z|[+-]\d{2}:\d{2}))?$/;
const ENUM_VALUE = /^[a-z][a-z0-9_]*$/;

/** `sha256Hex(jcs(args))`: the read key's second half. */
export function argsHash(args: Record<string, unknown>): string {
  return sha256Hex(jcs(args));
}

function readKey(capability: string, hash: string): string {
  return `${capability}\u0000${hash}`;
}

/** Deep copy through JCS: also proves the value is plain JSON. */
function copy<T>(value: T): T {
  return JSON.parse(jcs(value)) as T;
}

function pointerToken(key: string | number): string {
  return String(key).replace(/~/g, "~0").replace(/\//g, "~1");
}

function checkTokenised(value: unknown, pointer: string, where: string, enums: ReadonlySet<string>): void {
  if (value === null || typeof value === "number" || typeof value === "boolean") return;
  if (typeof value === "string") {
    if (FIXTURE_TOKEN.test(value) || ISO_DATE.test(value) || enums.has(value)) return;
    throw new FakeConnectorError(
      "untokenised_value",
      `fake connector: untokenised string at ${where} ${pointer || "/"}; fixture values must be fixture tokens, ISO dates or listed enum values`,
    );
  }
  if (Array.isArray(value)) {
    value.forEach((v, i) => checkTokenised(v, `${pointer}/${i}`, where, enums));
    return;
  }
  if (typeof value === "object") {
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      checkTokenised(v, `${pointer}/${pointerToken(k)}`, where, enums);
    }
    return;
  }
  throw new FakeConnectorError("invalid_fixture", `fake connector: non-JSON value at ${where} ${pointer || "/"}`);
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

export function fakeConnector(fixtureSet: FixtureSet): FakeConnector {
  if (!isRecord(fixtureSet) || !Array.isArray(fixtureSet.reads)) {
    throw new FakeConnectorError("invalid_fixture", "fake connector: a fixture set needs a reads array");
  }
  const enumList = fixtureSet.enum_values ?? [];
  for (const [i, e] of enumList.entries()) {
    if (typeof e !== "string" || !ENUM_VALUE.test(e)) {
      throw new FakeConnectorError("invalid_fixture", `fake connector: enum_values/${i} is not a lower-case identifier`);
    }
  }
  const enums: ReadonlySet<string> = new Set(enumList);

  const recordings = new Map<string, string>(); // read key -> JCS of the output
  fixtureSet.reads.forEach((r, i) => {
    if (!isRecord(r) || typeof r.capability !== "string" || r.capability === "" || !isRecord(r.args)) {
      throw new FakeConnectorError("invalid_fixture", `fake connector: reads/${i} needs a capability and an args object`);
    }
    checkTokenised(r.args, "", `reads/${i}/args`, enums);
    checkTokenised(r.output, "", `reads/${i}/output`, enums);
    const hash = argsHash(r.args);
    const key = readKey(r.capability, hash);
    if (recordings.has(key)) {
      throw new FakeConnectorError(
        "duplicate_recording",
        `fake connector: two recordings for capability ${r.capability} args_hash ${hash}`,
      );
    }
    recordings.set(key, jcs(r.output));
  });
  (fixtureSet.expected_items ?? []).forEach((item, i) => {
    if (!isRecord(item) || !isRecord(item.args)) {
      throw new FakeConnectorError("invalid_fixture", `fake connector: expected_items/${i} needs an args object`);
    }
    checkTokenised(item.args, "", `expected_items/${i}/args`, enums);
  });

  const committed: RecordedItem[] = [];
  const misses: MissedRead[] = [];

  return {
    async read(capability, args) {
      const hash = argsHash(args);
      const recorded = recordings.get(readKey(capability, hash));
      if (recorded === undefined) {
        misses.push({ capability, args_hash: hash });
        throw new FakeConnectorError(
          "no_recording",
          `fake connector: no recording for capability ${capability} args_hash ${hash}`,
        );
      }
      return JSON.parse(recorded) as unknown;
    },

    async commit(items) {
      const batch = items.map((input, i) => {
        const hash = itemHash(input);
        if (input.item_hash !== undefined && input.item_hash !== hash) {
          throw new FakeConnectorError(
            "item_hash_mismatch",
            `fake connector: commit item ${i} (capability ${input.capability}) has item_hash ${input.item_hash}, expected ${hash}`,
          );
        }
        const recorded: RecordedItem = {
          item_key: input.item_key,
          item_hash: hash,
          capability: input.capability,
          connection_ref: input.connection_ref,
          args: copy(input.args),
        };
        return recorded;
      });
      committed.push(...batch);
      return batch.map((r) => ({ item_key: r.item_key, item_hash: r.item_hash, outcome: "recorded" as const }));
    },

    items() {
      return committed.map((r) => copy(r));
    },

    missedReads() {
      return misses.map((m) => ({ ...m }));
    },

    assertNoMissedReads() {
      if (misses.length === 0) return;
      const list = misses.map((m) => `${m.capability} args_hash ${m.args_hash}`).join("; ");
      throw new FakeConnectorError(
        "missed_reads",
        `fake connector: ${misses.length} read(s) had no recording: ${list}`,
      );
    },
  };
}
