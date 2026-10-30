// Interfaces the app depends on. Adapters in src/adapters/* implement them.

export interface Clock {
  now(): Date;
}

export interface HealthProbe {
  /** Returns true when the storage backend answers. */
  check(): Promise<boolean>;
}

export type ClientType = "ios" | "android" | "web";
export type Scope = "app" | "activities:write";

export interface UserRecord {
  id: string;
  email: string;
  createdAt: string;
}

export interface CodeRecord {
  codeHash: string;
  expiresAt: string;
  attempts: number;
}

export interface RefreshRecord {
  id: string;
  userId: string;
  /** All tokens descended from one sign-in; revoked together when a rotated token is reused. */
  familyId: string;
  tokenHash: string;
  clientType: ClientType;
  scopes: Scope[];
  createdAt: string;
  expiresAt: string;
  rotatedAt: string | null;
  revokedAt: string | null;
}

/** Users, one-time codes and refresh tokens. Only hashes are stored, never a code or a token in clear. */
export interface AuthStore {
  /** Keeps one code per email: a new code replaces the old one and resets its attempts. */
  saveCode(email: string, codeHash: string, expiresAt: string, now: string): Promise<void>;
  getCode(email: string): Promise<CodeRecord | undefined>;
  /**
   * Takes one of the `max` attempts a code allows. Atomic, so parallel guesses cannot exceed the limit: false when
   * the attempts are used up (or there is no code).
   */
  useCodeAttempt(email: string, max: number): Promise<boolean>;
  /** True only for the caller that removed it, so a code is single use even when requests race. */
  deleteCode(email: string): Promise<boolean>;
  findOrCreateUser(email: string, newId: string, now: string): Promise<{ user: UserRecord; created: boolean }>;
  userExists(id: string): Promise<boolean>;
  saveRefresh(record: RefreshRecord): Promise<void>;
  findRefresh(tokenHash: string): Promise<RefreshRecord | undefined>;
  /** True only for the caller that rotated it; false when it was already rotated or revoked. */
  markRefreshRotated(id: string, at: string): Promise<boolean>;
  revokeFamily(familyId: string, at: string): Promise<void>;
  /** Removes the user and everything they own (account delete). */
  deleteUser(id: string): Promise<void>;
}

/** Sends the one-time sign-in code. Dev logs it; production sends email. */
export interface EmailSender {
  sendCode(to: string, code: string): Promise<void>;
}

export interface RateLimiter {
  /** Counts a hit in a fixed window. When over the limit, says how many seconds until the window ends. */
  hit(key: string, limit: number, windowSec: number, now: Date): Promise<{ allowed: boolean; retryAfterSec: number }>;
}

/** Randomness, kept behind a port so domain code and tests stay deterministic where they need to be. */
export interface IdSource {
  uuid(): string;
  /** Six decimal digits. */
  code(): string;
  /** An unguessable opaque token, URL-safe. */
  token(): string;
}

export interface AuthConfig {
  /** HS256 signing secret for access tokens. */
  jwtSecret: string;
}

export interface Deps {
  clock: Clock;
  health: HealthProbe;
  auth: AuthStore;
  email: EmailSender;
  rateLimiter: RateLimiter;
  ids: IdSource;
  authConfig: AuthConfig;
}
