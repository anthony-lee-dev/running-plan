// Interfaces the app depends on. Adapters in src/adapters/* implement them.
import type { Profile, ProfileFields } from "../domain/profile";
import type { PlanFieldsInput, SessionContent } from "../domain/plan-input";
import type { StoredActivity } from "../domain/activities";
import type { MatchEffects, MatchRow, MatchState } from "../domain/matches";
import type { CheckInFields } from "../domain/checkins";

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

export interface ActivityQuery {
  from?: string;
  to?: string;
  /** Only activities still waiting for review. */
  inbox?: boolean;
  limit: number;
  /** The last activity of the previous page. */
  after?: { localDate: string; startedAt: string; id: string };
}

/** Imported activities, scoped to the user. Kept to a few queries per call: Workers Free allows 50 a request. */
export interface ActivityStore {
  /**
   * What an upload is deduped against: the user's activities whose local date is in [from, to], plus any with one of
   * these source ids whatever its date (deleted ones included, so an id is never reused).
   */
  candidates(userId: string, from: string, to: string, keys: { source: string; externalId: string }[]): Promise<StoredActivity[]>;
  /**
   * Inserts and updates in one transaction. An insert that clashes with a stored source id fails the whole import
   * (throws) rather than being dropped. Updates name ids just read for this user; another user's row is never changed.
   */
  applyImport(userId: string, creates: StoredActivity[], updates: StoredActivity[]): Promise<void>;
  get(userId: string, id: string): Promise<StoredActivity | undefined>;
  /** Newest first: local date, then start, then id, all descending. */
  list(userId: string, query: ActivityQuery): Promise<StoredActivity[]>;
}

/** Thrown by `MatchStore.apply` when something it read has changed since; nothing was written. */
export class MatchConflictError extends Error {
  override name = "MatchConflictError";
}

/** Matches between activities and sessions, written together with the session status and activity disposition. */
export interface MatchStore {
  /**
   * The state a match change looks at: the user's live session and activity named (when they exist), their current
   * matches, and the session or activity on the other end of those matches.
   */
  load(userId: string, ref: { sessionId?: string; activityId?: string }): Promise<MatchState>;
  /** Writes the effects in one transaction, or throws MatchConflictError if anything in `state` has changed. */
  apply(userId: string, state: MatchState, effects: MatchEffects, now: string): Promise<void>;
  /** The matches of these activities whose session is still live. */
  forActivities(userId: string, activityIds: string[]): Promise<MatchRow[]>;
  /**
   * What an upload may suggest: the user's live `planned` sessions of live plans with a date in [from, to] that have
   * no match yet. One query.
   */
  suggestionCandidates(userId: string, from: string, to: string): Promise<StoredSession[]>;
}

export interface StoredCheckIn extends CheckInFields {
  id: string;
  sessionId: string;
  revision: number;
  updatedAt: string;
  deletedAt: string | null;
}

/** Before- and after-session check-ins, on the user's live sessions. */
export interface CheckInStore {
  /** Idempotent on the id: an existing id is reported with the stored check-in when it is this user's. */
  create(
    userId: string,
    checkIn: StoredCheckIn,
  ): Promise<{ status: "created"; checkIn: StoredCheckIn } | { status: "exists"; mine: true; checkIn: StoredCheckIn } | { status: "exists"; mine: false } | { status: "no_session" }>;
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
  activities: ActivityStore;
  matches: MatchStore;
  checkIns: CheckInStore;
  email: EmailSender;
  rateLimiter: RateLimiter;
  ids: IdSource;
  authConfig: AuthConfig;
}
