/**
 * Fake connector (m1-05-routine-contract, ADR 0026, ADR 0027).
 * Serves recorded reads keyed by (capability, args hash), records commit items without executing them, and fails the
 * test on any read it has no recording for. Fixture values must be fixture tokens (`tok_` + 12 hex); see
 * `fakeConnector` for the strings that may stay as they are.
 * STUB: phase 1 (red tests). Every function throws until it is implemented.
 */

/** One unit of work a commit step returns. Matches the SDK's `Item` (SPEC "Commit steps return items"). */
export type Item = {
  item_key: string;
  capability: string;
  connection_ref: string;
  args: Record<string, unknown>;
};

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
  expected_items?: Item[];
  enum_values?: string[];
};

/** A commit item as the fake recorded it. */
export type RecordedItem = Item & { item_hash: string };

export type CommitResult = { item_key: string; item_hash: string; outcome: "recorded" };

/** A read the fake had no recording for. Never holds the arg values, only their hash. */
export type MissedRead = { capability: string; args_hash: string };

export type FakeConnectorErrorCode =
  | "no_recording"
  | "missed_reads"
  | "untokenised_value"
  | "duplicate_recording"
  | "invalid_fixture";

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
  /** Records the items (deep copies) with their item_hash. Never executes anything. */
  commit(items: readonly Item[]): Promise<CommitResult[]>;
  /** Every item committed so far, in order (deep copies). */
  items(): RecordedItem[];
  /** Every read that had no recording, in order. */
  missedReads(): MissedRead[];
  /** Throws `missed_reads` if any read had no recording, even when the caller swallowed the read's error. */
  assertNoMissedReads(): void;
}

/** `sha256Hex(jcs(args))`: the read key's second half. */
export function argsHash(_args: Record<string, unknown>): string {
  throw new Error("not implemented");
}

/** `sha256Hex(jcs({ capability, connection_ref, args }))`. */
export function itemHash(_item: Pick<Item, "capability" | "connection_ref" | "args">): string {
  throw new Error("not implemented");
}

export function fakeConnector(_fixtureSet: FixtureSet): FakeConnector {
  throw new Error("not implemented");
}
