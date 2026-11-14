import { z } from "zod";

/** Stub (red). */
export const DEVICE_CAPABILITIES = [] as readonly string[];
export const RoutineDefinitionSchema: z.ZodType<any> = z.never();
export const ResolvedRoutineDefinitionSchema: z.ZodType<any> = z.never();
export type RoutineStep = { id: string } & Record<string, unknown>;
export type RoutineDefinition = { steps: RoutineStep[]; limits: { quiet_hours: unknown } };
export type ResolvedStep = RoutineStep;
export type ResolvedRoutineDefinition = RoutineDefinition;
export function parseRoutine(_doc: unknown): RoutineDefinition {
  throw new Error("not implemented");
}
