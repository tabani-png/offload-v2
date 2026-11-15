/** The one clock the API decides expiry with (tests pass testkit's FakeClock). */
export interface Clock {
  now(): Date;
}

export const systemClock: Clock = { now: () => new Date() };
