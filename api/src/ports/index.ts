// Interfaces the app depends on. Adapters in src/adapters/* implement them.

export interface Clock {
  now(): Date;
}

export interface HealthProbe {
  /** Returns true when the storage backend answers. */
  check(): Promise<boolean>;
}

export interface Deps {
  clock: Clock;
  health: HealthProbe;
}
