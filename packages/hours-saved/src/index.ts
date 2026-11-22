/**
 * @offload/hours-saved
 * hs-1 measured hours saved. Pure functions, numbers from code only.
 *
 * Architecture only. No feature code yet. See docs/adr/0003-numbers-come-from-code.md.
 * The first slice that touches this package replaces this marker.
 */
export type TodoHoursSaved = "TODO: not implemented. See docs/adr/0003-numbers-come-from-code.md";

/** Measured saving after a fix ships (slice p45b). Types only here; runtime from "./measured/index.ts". */
export type { Evidence, Figure } from "./measured/figure.ts";
export type { FixOutcome, OutcomeFlag, OutcomeWeek, ShipInput, WeekValue } from "./measured/outcome.ts";
