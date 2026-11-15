import { type Capability, CapabilitySchema } from "@offload/contracts/src/connections/index.ts";

/**
 * The fixed capability vocabulary (ARCHITECTURE section 10). Each capability has a step class and a JSON Schema for
 * its arguments; a `commit` capability also names the only arguments a commit may carry. Ported in behaviour from the
 * old `connectors/capabilities.ts`.
 */

export class CapabilityLoadError extends Error {
  readonly code = "capability_invalid";
  constructor(message: string) {
    super(message);
    this.name = "CapabilityLoadError";
  }
}

type Prop = Record<string, unknown>;
const str: Prop = { type: "string", minLength: 1 };
const strs: Prop = { type: "array", items: { type: "string", minLength: 1 } };
const int: Prop = { type: "integer", minimum: 1 };
const dateTime: Prop = { type: "string", format: "date-time" };

function args(properties: Record<string, Prop>, required: string[] = []): Record<string, unknown> {
  return { type: "object", properties, required, additionalProperties: false };
}

function read(name: string, argument_schema: Record<string, unknown>): Capability {
  return { name, step_class: "read", argument_schema };
}
function draft(name: string, argument_schema: Record<string, unknown>): Capability {
  return { name, step_class: "draft", argument_schema };
}
function commit(name: string, argument_schema: Record<string, unknown>, allowlist: string[]): Capability {
  return { name, step_class: "commit", argument_schema, commit_arguments_allowlist: allowlist };
}

const mailMessage = { to: strs, cc: strs, subject: str, body: { type: "string" }, thread_id: str };

export const CAPABILITY_DEFS: readonly Capability[] = [
  read("mail.search", args({ query: str, max_results: int }, ["query"])),
  read("mail.read", args({ message_id: str }, ["message_id"])),
  draft("mail.draft", args(mailMessage, ["to", "subject", "body"])),
  commit("mail.send", args(mailMessage, ["to", "subject", "body"]), ["to", "cc", "subject", "body", "thread_id"]),
  read("calendar.events", args({ calendar_id: str, time_min: dateTime, time_max: dateTime }, ["time_min", "time_max"])),
  commit(
    "calendar.create_event",
    args({ calendar_id: str, title: str, start: dateTime, end: dateTime, attendees: strs }, ["title", "start", "end"]),
    ["calendar_id", "title", "start", "end", "attendees"],
  ),
  read("sheet.read", args({ spreadsheet_id: str, range: str }, ["spreadsheet_id", "range"])),
  commit(
    "sheet.append",
    args({ spreadsheet_id: str, range: str, rows: { type: "array", items: { type: "array" } } }, [
      "spreadsheet_id",
      "range",
      "rows",
    ]),
    ["spreadsheet_id", "range", "rows"],
  ),
  commit(
    "sheet.update",
    args({ spreadsheet_id: str, range: str, rows: { type: "array", items: { type: "array" } } }, [
      "spreadsheet_id",
      "range",
      "rows",
    ]),
    ["spreadsheet_id", "range", "rows"],
  ),
  read("drive.files", args({ query: str, folder_id: str, max_results: int })),
  commit("message.post", args({ channel: str, text: str, thread_ts: str }, ["channel", "text"]), [
    "channel",
    "text",
    "thread_ts",
  ]),
  read("channel.history", args({ channel: str, since: dateTime, max_results: int }, ["channel"])),
  read("page.read", args({ page_id: str }, ["page_id"])),
  commit("page.create", args({ parent_id: str, title: str, content: { type: "string" } }, ["parent_id", "title"]), [
    "parent_id",
    "title",
    "content",
  ]),
  read("issue.list", args({ team_id: str, state: str, max_results: int })),
  commit("issue.create", args({ team_id: str, title: str, description: { type: "string" } }, ["team_id", "title"]), [
    "team_id",
    "title",
    "description",
  ]),
  read("payouts.list", args({ created_from: dateTime, created_to: dateTime, max_results: int })),
  read("balance.read", args({})),
  read("invoice.list", args({ customer_id: str, status: str, max_results: int })),
  commit(
    "invoice.create",
    args(
      {
        customer_id: str,
        currency: { type: "string", pattern: "^[A-Z]{3}$" },
        lines: { type: "array", items: { type: "object" } },
        due_date: { type: "string", format: "date" },
      },
      ["customer_id", "currency", "lines"],
    ),
    ["customer_id", "currency", "lines", "due_date"],
  ),
];

/** Validates a list of capability definitions. Throws CapabilityLoadError on the first problem. */
export function loadCapabilities(defs: unknown[]): Capability[] {
  const seen = new Set<string>();
  const out: Capability[] = [];
  for (const [i, def] of defs.entries()) {
    const parsed = CapabilitySchema.safeParse(def);
    if (!parsed.success) throw new CapabilityLoadError(`capability ${i} is not a valid Capability`);
    const cap = parsed.data;
    if (seen.has(cap.name)) throw new CapabilityLoadError(`duplicate capability ${cap.name}`);
    seen.add(cap.name);
    const allowlist = cap.commit_arguments_allowlist;
    if (cap.step_class === "commit" && allowlist === undefined) {
      throw new CapabilityLoadError(`commit capability ${cap.name} has no argument allowlist`);
    }
    if (cap.step_class !== "commit" && allowlist !== undefined) {
      throw new CapabilityLoadError(`${cap.step_class} capability ${cap.name} must not have an argument allowlist`);
    }
    if (allowlist !== undefined) {
      const props = cap.argument_schema["properties"];
      const names =
        props !== null && typeof props === "object" && !Array.isArray(props) ? Object.keys(props) : ([] as string[]);
      for (const arg of allowlist) {
        if (!names.includes(arg)) {
          throw new CapabilityLoadError(`capability ${cap.name} allowlists ${arg}, which is not in its argument schema`);
        }
      }
    }
    out.push(cap);
  }
  return out;
}

/** Loaded at import, so a bad definition fails the module load. */
export const CAPABILITIES: readonly Capability[] = Object.freeze(loadCapabilities([...CAPABILITY_DEFS]));

const BY_NAME = new Map(CAPABILITIES.map((c) => [c.name, c]));

export function capabilityNames(): string[] {
  return CAPABILITIES.map((c) => c.name);
}

export function findCapability(name: string): Capability | undefined {
  return BY_NAME.get(name);
}
