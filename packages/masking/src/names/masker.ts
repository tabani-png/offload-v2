export interface NameMaskerOptions {
  ownName?: string;
  ownNameToModels?: "mask" | "keep";
  /** Random source for the run tag; defaults to crypto randomness. */
  random?: () => number;
}

export interface NameMasker {
  readonly tag: string;
  mask(text: string): string;
}

export function createNameMasker(_opts: NameMaskerOptions = {}): NameMasker {
  throw new Error("not implemented");
}
