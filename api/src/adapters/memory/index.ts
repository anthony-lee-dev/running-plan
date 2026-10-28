import type { Clock, Deps, HealthProbe } from "../../ports";

export const systemClock: Clock = { now: () => new Date() };

export class FixedClock implements Clock {
  constructor(private readonly at: Date) {}
  now(): Date {
    return this.at;
  }
}

export class MemoryHealthProbe implements HealthProbe {
  async check(): Promise<boolean> {
    return true;
  }
}

export function memoryDeps(overrides: Partial<Deps> = {}): Deps {
  return { clock: systemClock, health: new MemoryHealthProbe(), ...overrides };
}
