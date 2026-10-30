// Interfaces the app depends on. Adapters in src/adapters/* implement them.
import type { Profile, ProfileFields } from "../domain/profile";
import type { PlanFieldsInput, SessionContent } from "../domain/plan-input";

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

/** One profile per user. Nothing is stored until the first save; until then the user has the default, revision 1. */
export interface ProfileStore {
  get(userId: string): Promise<Profile | undefined>;
  /**
   * Stores `fields` as revision `baseRevision + 1`, but only if the stored revision is `baseRevision` (1 when
   * nothing is stored). Atomic: of two racing saves against one revision, exactly one wins.
   */
  save(
    userId: string,
    baseRevision: number,
    fields: ProfileFields,
    now: string,
  ): Promise<{ ok: true; profile: Profile } | { ok: false; currentRevision: number }>;
}

export interface StoredPlan extends PlanFieldsInput {
  id: string;
  revision: number;
  /** Moves on any change to the plan or one of its sessions; proposals go stale when it moves. */
  contentRevision: number;
  updatedAt: string;
  deletedAt: string | null;
}

export interface StoredSession extends SessionContent {
  id: string;
  planId: string;
  revision: number;
  updatedAt: string;
  deletedAt: string | null;
}

export type CreateOutcome =
  | { status: "created" }
  /** A session id in the plan is already in use (by any user): nothing was written. */
  | { status: "conflict" }
  /** The id is taken. `mine` is false when another user holds it, which must never be revealed. */
  | { status: "exists"; mine: boolean; createHash: string | null };

export type WriteFailure = { ok: false; reason: "not_found" } | { ok: false; reason: "conflict"; currentRevision: number };

/** The plan fields a write replaces. Weeks listed here replace the plan's weeks. */
export type PlanWriteFields = Pick<StoredPlan, "goal" | "adaptive" | "weeks">;

/**
 * Plans, their weeks and sessions, all scoped to the signed-in user: another user's id is simply not found.
 * Writes compare the base revision atomically; a session write also moves the plan's contentRevision, in the
 * same transaction. Deletes are tombstones.
 */
export interface PlanStore {
  /** Idempotent on the plan id. Stores the hash of the request so a replay can be told from a different body. */
  createPlan(userId: string, plan: StoredPlan, sessions: StoredSession[], createHash: string): Promise<CreateOutcome>;
  /** The plan with its live sessions; undefined when missing, another user's, or deleted. */
  getPlan(userId: string, planId: string): Promise<{ plan: StoredPlan; sessions: StoredSession[]; createHash: string | null } | undefined>;
  /** Live plans, newest first (start date, then id), without weeks. `after` is the last plan of the previous page. */
  listPlans(userId: string, limit: number, after?: { startDate: string; id: string }): Promise<StoredPlan[]>;
  writePlan(userId: string, planId: string, baseRevision: number, fields: PlanWriteFields, now: string): Promise<{ ok: true; plan: StoredPlan } | WriteFailure>;
  deletePlan(userId: string, planId: string, baseRevision: number, now: string): Promise<{ ok: true } | WriteFailure>;

  createSession(
    userId: string,
    session: StoredSession,
    createHash: string,
  ): Promise<{ status: "created"; contentRevision: number } | { status: "exists"; mine: boolean; createHash: string | null; session?: StoredSession; contentRevision?: number } | { status: "no_plan" }>;
  /** A live session of a live plan of this user, with that plan (without weeks or sessions). */
  getSession(userId: string, sessionId: string): Promise<{ session: StoredSession; plan: StoredPlan; createHash: string | null } | undefined>;
  /** Replaces the session's content when `baseRevision` is current. */
  writeSession(userId: string, sessionId: string, baseRevision: number, next: SessionContent, now: string): Promise<{ ok: true; session: StoredSession; contentRevision: number } | WriteFailure>;
  deleteSession(userId: string, sessionId: string, baseRevision: number, now: string): Promise<{ ok: true; session: StoredSession; contentRevision: number } | WriteFailure>;
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
  profiles: ProfileStore;
  plans: PlanStore;
  email: EmailSender;
  rateLimiter: RateLimiter;
  ids: IdSource;
  authConfig: AuthConfig;
}
