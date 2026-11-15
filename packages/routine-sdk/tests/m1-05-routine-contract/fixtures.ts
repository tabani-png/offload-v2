import type { PinnedConnection } from "../../src/index.ts";

/**
 * Synthetic routines for the m1-05 tests. "Weekly payouts to the finance sheet": read payouts, transform them to rows,
 * draft a note, append one row per item, ask the classify route for a summary, run a Shortcut on the Mac.
 * Every value is made up; strings that stand for connector content are fixture tokens (tok_ + 12 hex).
 */
export function validRoutine(): Record<string, unknown> {
  return {
    v: 1,
    name: "Weekly payouts to the finance sheet",
    trigger: { kind: "schedule", cron: "0 9 * * 1", timezone: "Europe/London" },
    steps: [
      { id: "payouts", class: "read", runs_on: "cloud", capability: "payouts.list", connection_ref: "stripe", args: { limit: "50" } },
      {
        id: "rows", class: "transform", runs_on: "cloud", transform: "transforms/payouts_to_rows.ts",
        args: { payouts: "{{ steps.payouts.output/data }}" },
      },
      {
        id: "draft_note", class: "draft", runs_on: "cloud", capability: "mail.draft", connection_ref: "gmail",
        args: { to: "tok_0123456789ab", body: "Payouts: {{ steps.rows.output/count }} rows" },
      },
      {
        id: "append", class: "commit", runs_on: "cloud", capability: "sheet.append", connection_ref: "finance_sheet",
        foreach: "rows", args: { sheet: "tok_aaaaaaaaaaaa", values: ["{{ item.date }}", "{{ item.amount }}"] },
      },
      {
        id: "summary", class: "model", runs_on: "cloud",
        model: { route: "classify", prompt_ref: "prompts/summary.md", output_schema_ref: "schemas/summary.json" },
        args: { rows: "{{ steps.rows.output }}" },
      },
      {
        id: "notify", class: "commit", runs_on: "device", capability: "shortcut.run", connection_ref: "mac",
        args: { shortcut: "tok_bbbbbbbbbbbb", text: "Appended {{ steps.rows.output/count }} rows" },
      },
    ],
    limits: {
      max_items_per_run: 50, max_runs_per_day: 1, run_budget_usd: 0.5,
      quiet_hours: { start: "01:00", end: "03:59" }, recipients_from: "payouts",
    },
    capabilities: ["payouts.list", "mail.draft", "sheet.append", "shortcut.run"],
  };
}

export const PIN_HASH_A = "a".repeat(64);
export const PIN_HASH_B = "b".repeat(64);

/** The brief's pinned connections for validRoutine(). Account labels are synthetic. */
export function pins(): PinnedConnection[] {
  return [
    {
      connection_ref: "stripe", connection_id: "0193a000-0000-7000-8000-000000000001", adapter: "openapi",
      provider: "stripe", account_label: "acme-live",
      tools: [{ capability: "payouts.list", tool_name: "list_payouts", tool_pin_hash: PIN_HASH_A }],
    },
    {
      connection_ref: "gmail", connection_id: "0193a000-0000-7000-8000-000000000002", adapter: "composio",
      provider: "google", account_label: "your Workspace account",
      tools: [{ capability: "mail.draft", tool_name: "GMAIL_CREATE_DRAFT", tool_pin_hash: PIN_HASH_A }],
    },
    {
      connection_ref: "finance_sheet", connection_id: "0193a000-0000-7000-8000-000000000003", adapter: "mcp",
      provider: "google", account_label: "your Workspace account",
      tools: [{ capability: "sheet.append", tool_name: "append_row", tool_pin_hash: PIN_HASH_A }],
    },
    {
      connection_ref: "mac", connection_id: "0193a000-0000-7000-8000-000000000004", adapter: "device",
      provider: "mac", account_label: "Mac 1",
      tools: [{ capability: "shortcut.run", tool_name: "shortcut.run", tool_pin_hash: PIN_HASH_A }],
    },
  ];
}

/** Deep copy, then apply `edit`. */
export function edited(edit: (r: any) => void): Record<string, unknown> {
  const r = structuredClone(validRoutine());
  edit(r);
  return r;
}
