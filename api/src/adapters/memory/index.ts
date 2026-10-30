import type { Profile, ProfileFields } from "../../domain/profile";
import type { SessionContent } from "../../domain/plan-input";
import type { StoredActivity } from "../../domain/activities";
import type { MatchEffects, MatchRow, MatchState } from "../../domain/matches";
import type {
  ActivityQuery,
  ActivityStore,
  MatchStore,
  AuthStore,
  Clock,
  CodeRecord,
  Deps,
  EmailSender,
  HealthProbe,
  IdSource,
  ProfileStore,
  PlanStore,
  PlanWriteFields,
  RateLimiter,
  RefreshRecord,
  StoredPlan,
  StoredSession,
  UserRecord,
  WriteFailure,
} from "../../ports";
import { MatchConflictError } from "../../ports";

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

/** Randomness from Web Crypto, which Workers and Node both have. */
export const webIdSource: IdSource = {
  uuid: () => crypto.randomUUID(),
  code() {
    const limit = 4_294_000_000; // largest multiple of 1,000,000 below 2^32, so every code is equally likely
    const word = new Uint32Array(1);
    do crypto.getRandomValues(word);
    while (word[0]! >= limit);
    return String(word[0]! % 1_000_000).padStart(6, "0");
  },
  token() {
    const bytes = crypto.getRandomValues(new Uint8Array(32));
    return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  },
};

/** Keeps what it was asked to send, for tests. */
export class MemoryEmailSender implements EmailSender {
  readonly sent: { to: string; code: string }[] = [];
  async sendCode(to: string, code: string): Promise<void> {
    this.sent.push({ to, code });
  }
}

/** Development sender: prints the code instead of emailing it. Never use it in production. */
export class LogEmailSender implements EmailSender {
  async sendCode(to: string, code: string): Promise<void> {
    console.log(`[dev] sign-in code for ${to}: ${code}`);
  }
}

export class MemoryAuthStore implements AuthStore {
  private users = new Map<string, UserRecord>();
  private codes = new Map<string, CodeRecord>();
  private refresh = new Map<string, RefreshRecord>();

  async saveCode(email: string, codeHash: string, expiresAt: string): Promise<void> {
    this.codes.set(email, { codeHash, expiresAt, attempts: 0 });
  }
  async getCode(email: string): Promise<CodeRecord | undefined> {
    const code = this.codes.get(email);
    return code && { ...code };
  }
  async useCodeAttempt(email: string, max: number): Promise<boolean> {
    const code = this.codes.get(email);
    if (!code || code.attempts >= max) return false;
    code.attempts += 1;
    return true;
  }
  async deleteCode(email: string): Promise<boolean> {
    return this.codes.delete(email);
  }
  async findOrCreateUser(email: string, newId: string, now: string) {
    const existing = [...this.users.values()].find((u) => u.email === email);
    if (existing) return { user: { ...existing }, created: false };
    const user = { id: newId, email, createdAt: now };
    this.users.set(newId, user);
    return { user: { ...user }, created: true };
  }
  async userExists(id: string): Promise<boolean> {
    return this.users.has(id);
  }
  async saveRefresh(record: RefreshRecord): Promise<void> {
    this.refresh.set(record.id, { ...record, scopes: [...record.scopes] });
  }
  async findRefresh(tokenHash: string): Promise<RefreshRecord | undefined> {
    const found = [...this.refresh.values()].find((r) => r.tokenHash === tokenHash);
    return found && { ...found, scopes: [...found.scopes] };
  }
  async markRefreshRotated(id: string, at: string): Promise<boolean> {
    const record = this.refresh.get(id);
    if (!record || record.rotatedAt !== null || record.revokedAt !== null) return false;
    record.rotatedAt = at;
    return true;
  }
  async revokeFamily(familyId: string, at: string): Promise<void> {
    for (const record of this.refresh.values()) {
      if (record.familyId === familyId && record.revokedAt === null) record.revokedAt = at;
    }
  }
  async deleteUser(id: string): Promise<void> {
    this.users.delete(id);
    for (const [key, record] of this.refresh) if (record.userId === id) this.refresh.delete(key);
  }
}

export class MemoryProfileStore implements ProfileStore {
  private profiles = new Map<string, Profile>();

  /** Takes the auth store so a profile disappears with its account, as the database cascade does. */
  constructor(private readonly auth: AuthStore) {}

  async get(userId: string): Promise<Profile | undefined> {
    if (!(await this.auth.userExists(userId))) return undefined;
    const profile = this.profiles.get(userId);
    return profile && structuredClone(profile);
  }

  async save(userId: string, baseRevision: number, fields: ProfileFields, now: string) {
    if (!(await this.auth.userExists(userId))) return { ok: false as const, currentRevision: 1 };
    // From here to the set there is no await, so two racing saves cannot both pass the check.
    const current = this.profiles.get(userId)?.revision ?? 1;
    if (current !== baseRevision) return { ok: false as const, currentRevision: current };
    const profile: Profile = { ...structuredClone(fields), revision: baseRevision + 1, updatedAt: now };
    this.profiles.set(userId, profile);
    return { ok: true as const, profile: structuredClone(profile) };
  }
}

interface PlanEntry {
  userId: string;
  plan: StoredPlan;
  createHash: string;
  sessions: Map<string, { session: StoredSession; createHash: string }>;
}

/**
 * Plans in memory. Every method checks and writes with no await in between, so racing writes behave like the
 * database's atomic compare-and-set.
 */
export class MemoryPlanStore implements PlanStore {
  private plans = new Map<string, PlanEntry>();

  /** Takes the auth store so plans disappear with their account, as the database cascade does. */
  constructor(private readonly auth: AuthStore) {}

  private live(userId: string, planId: string): PlanEntry | undefined {
    const entry = this.plans.get(planId);
    return entry && entry.userId === userId && entry.plan.deletedAt === null ? entry : undefined;
  }

  private findSession(userId: string, sessionId: string) {
    for (const entry of this.plans.values()) {
      if (entry.userId !== userId || entry.plan.deletedAt !== null) continue;
      const found = entry.sessions.get(sessionId);
      if (found && found.session.deletedAt === null) return { entry, ...found };
    }
    return undefined;
  }

  /** The live session object itself (not a copy), with its plan entry; for MemoryMatchStore only. */
  sessionRef(userId: string, sessionId: string) {
    return this.findSession(userId, sessionId);
  }

  private sessionIdTaken(sessionId: string): { entry: PlanEntry; session: StoredSession; createHash: string } | undefined {
    for (const entry of this.plans.values()) {
      const found = entry.sessions.get(sessionId);
      if (found) return { entry, ...found };
    }
    return undefined;
  }

  private async userGone(userId: string): Promise<boolean> {
    return !(await this.auth.userExists(userId));
  }

  async createPlan(userId: string, plan: StoredPlan, sessions: StoredSession[], createHash: string) {
    if (await this.userGone(userId)) throw new Error("user does not exist");
    const existing = this.plans.get(plan.id);
    if (existing) return { status: "exists" as const, mine: existing.userId === userId, createHash: existing.userId === userId ? existing.createHash : null };
    if (sessions.some((s) => this.sessionIdTaken(s.id))) return { status: "conflict" as const };
    this.plans.set(plan.id, {
      userId,
      plan: structuredClone(plan),
      createHash,
      sessions: new Map(sessions.map((s) => [s.id, { session: structuredClone(s), createHash }])),
    });
    return { status: "created" as const };
  }

  async getPlan(userId: string, planId: string) {
    if (await this.userGone(userId)) return undefined;
    const entry = this.live(userId, planId);
    if (!entry) return undefined;
    const sessions = [...entry.sessions.values()].map((x) => x.session).filter((s) => s.deletedAt === null);
    return structuredClone({ plan: entry.plan, sessions, createHash: entry.createHash as string | null });
  }

  async listPlans(userId: string, limit: number, after?: { startDate: string; id: string }) {
    if (await this.userGone(userId)) return [];
    return [...this.plans.values()]
      .filter((e) => e.userId === userId && e.plan.deletedAt === null)
      .map((e) => structuredClone({ ...e.plan, weeks: [] }))
      .sort((a, b) => (a.startDate === b.startDate ? (a.id < b.id ? 1 : -1) : a.startDate < b.startDate ? 1 : -1))
      .filter((p) => !after || p.startDate < after.startDate || (p.startDate === after.startDate && p.id < after.id))
      .slice(0, limit);
  }

  async writePlan(userId: string, planId: string, baseRevision: number, fields: PlanWriteFields, now: string): Promise<{ ok: true; plan: StoredPlan } | WriteFailure> {
    const entry = this.live(userId, planId);
    if (!entry || (await this.userGone(userId))) return { ok: false, reason: "not_found" };
    if (entry.plan.revision !== baseRevision) return { ok: false, reason: "conflict", currentRevision: entry.plan.revision };
    entry.plan = { ...entry.plan, ...structuredClone(fields), revision: baseRevision + 1, contentRevision: entry.plan.contentRevision + 1, updatedAt: now };
    return { ok: true, plan: structuredClone(entry.plan) };
  }

  async deletePlan(userId: string, planId: string, baseRevision: number, now: string): Promise<{ ok: true } | WriteFailure> {
    const entry = this.live(userId, planId);
    if (!entry || (await this.userGone(userId))) return { ok: false, reason: "not_found" };
    if (entry.plan.revision !== baseRevision) return { ok: false, reason: "conflict", currentRevision: entry.plan.revision };
    entry.plan = { ...entry.plan, revision: baseRevision + 1, contentRevision: entry.plan.contentRevision + 1, updatedAt: now, deletedAt: now };
    return { ok: true };
  }

  async createSession(userId: string, session: StoredSession, createHash: string) {
    const entry = this.live(userId, session.planId);
    if (!entry || (await this.userGone(userId))) return { status: "no_plan" as const };
    const taken = this.sessionIdTaken(session.id);
    if (taken) {
      const mine = taken.entry.userId === userId;
      return mine
        ? { status: "exists" as const, mine, createHash: taken.createHash, session: structuredClone(taken.session), contentRevision: taken.entry.plan.contentRevision }
        : { status: "exists" as const, mine, createHash: null };
    }
    entry.sessions.set(session.id, { session: structuredClone(session), createHash });
    entry.plan = { ...entry.plan, contentRevision: entry.plan.contentRevision + 1 };
    return { status: "created" as const, contentRevision: entry.plan.contentRevision };
  }

  async getSession(userId: string, sessionId: string) {
    if (await this.userGone(userId)) return undefined;
    const found = this.findSession(userId, sessionId);
    return found && structuredClone({ session: found.session, plan: { ...found.entry.plan, weeks: [] }, createHash: found.createHash as string | null });
  }

  private change(userId: string, sessionId: string, baseRevision: number, apply: (s: StoredSession) => StoredSession) {
    const found = this.findSession(userId, sessionId);
    if (!found) return { ok: false as const, reason: "not_found" as const };
    if (found.session.revision !== baseRevision) return { ok: false as const, reason: "conflict" as const, currentRevision: found.session.revision };
    const session = apply(found.session);
    found.entry.sessions.set(sessionId, { session, createHash: found.createHash });
    found.entry.plan = { ...found.entry.plan, contentRevision: found.entry.plan.contentRevision + 1 };
    return { ok: true as const, session: structuredClone(session), contentRevision: found.entry.plan.contentRevision };
  }

  async writeSession(userId: string, sessionId: string, baseRevision: number, next: SessionContent, now: string) {
    if (await this.userGone(userId)) return { ok: false as const, reason: "not_found" as const };
    return this.change(userId, sessionId, baseRevision, (s) => ({ ...structuredClone(next), id: s.id, planId: s.planId, revision: baseRevision + 1, updatedAt: now, deletedAt: null }));
  }

  async deleteSession(userId: string, sessionId: string, baseRevision: number, now: string) {
    if (await this.userGone(userId)) return { ok: false as const, reason: "not_found" as const };
    return this.change(userId, sessionId, baseRevision, (s) => ({ ...s, revision: baseRevision + 1, updatedAt: now, deletedAt: now }));
  }
}

/** Newest first: local date, then start, then id. Negative when `a` comes first. */
// Plain code-unit comparison, as SQLite's default (binary) collation orders TEXT.
const cmp = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);
const newestFirst = (a: { localDate: string; startedAt: string; id: string }, b: { localDate: string; startedAt: string; id: string }) =>
  cmp(b.localDate, a.localDate) || cmp(b.startedAt, a.startedAt) || cmp(b.id, a.id);

export class MemoryActivityStore implements ActivityStore {
  private rows = new Map<string, { userId: string; activity: StoredActivity }>();

  /** Takes the auth store so activities disappear with their account, as the database cascade does. */
  constructor(private readonly auth: AuthStore) {}

  private async mine(userId: string): Promise<StoredActivity[]> {
    if (!(await this.auth.userExists(userId))) return [];
    return [...this.rows.values()].filter((r) => r.userId === userId).map((r) => structuredClone(r.activity));
  }

  /** The stored activity itself (not a copy); for MemoryMatchStore only. */
  ref(userId: string, id: string): StoredActivity | undefined {
    const row = this.rows.get(id);
    return row && row.userId === userId ? row.activity : undefined;
  }

  async get(userId: string, id: string) {
    return (await this.mine(userId)).find((a) => a.id === id);
  }

  async candidates(userId: string, from: string, to: string, keys: { source: string; externalId: string }[]) {
    const wanted = new Set(keys.map((k) => `${k.source}\u0000${k.externalId}`));
    return (await this.mine(userId)).filter((a) => (a.localDate >= from && a.localDate <= to) || wanted.has(`${a.source}\u0000${a.externalId}`));
  }

  async applyImport(userId: string, creates: StoredActivity[], updates: StoredActivity[]) {
    if (!(await this.auth.userExists(userId))) throw new Error("user does not exist");
    const taken = (a: StoredActivity) => [...this.rows.values()].some((r) => r.userId === userId && r.activity.source === a.source && r.activity.externalId === a.externalId && r.activity.id !== a.id);
    // Check everything first, as the database's transaction would roll back on the first failure.
    for (const a of creates) if (this.rows.has(a.id) || taken(a)) throw new Error("activity already exists");
    for (const a of updates) {
      const row = this.rows.get(a.id);
      if (!row || row.userId !== userId || taken(a)) throw new Error("activity update failed");
    }
    for (const a of creates) this.rows.set(a.id, { userId, activity: structuredClone(a) });
    for (const a of updates) this.rows.get(a.id)!.activity = structuredClone(a);
  }

  async list(userId: string, query: ActivityQuery) {
    const { from, to, inbox, limit, after } = query;
    return (await this.mine(userId))
      .filter((a) => (from === undefined || a.localDate >= from) && (to === undefined || a.localDate <= to) && (!inbox || a.disposition === "inbox"))
      .filter((a) => !after || newestFirst(after, a) < 0)
      .sort(newestFirst)
      .slice(0, limit);
  }
}

/** Matches in memory. `apply` checks and writes with no await in between, like the database's transaction. */
export class MemoryMatchStore implements MatchStore {
  private rows: (MatchRow & { userId: string })[] = [];

  constructor(
    private readonly auth: AuthStore,
    private readonly plans: MemoryPlanStore,
    private readonly activities: MemoryActivityStore,
  ) {}

  private snapshot(userId: string, ref: { sessionId?: string; activityId?: string }): MatchState {
    // Every match, also one whose session was deleted: the change then removes it.
    const matches = this.rows.filter((r) => r.userId === userId && (r.sessionId === ref.sessionId || r.activityId === ref.activityId));
    const sessionIds = new Set([...(ref.sessionId ? [ref.sessionId] : []), ...matches.map((r) => r.sessionId)].filter((id) => this.plans.sessionRef(userId, id)));
    const activityIds = new Set([...(ref.activityId ? [ref.activityId] : []), ...matches.map((r) => r.activityId)]);
    const sessions = [...sessionIds].flatMap((id) => {
      const s = this.plans.sessionRef(userId, id)?.session;
      return s ? [{ id: s.id, planId: s.planId, status: s.status, revision: s.revision }] : [];
    });
    const activities = [...activityIds].flatMap((id) => {
      const a = this.activities.ref(userId, id);
      return a ? [{ id: a.id, disposition: a.disposition, revision: a.revision }] : [];
    });
    return { sessions, activities, matches: matches.map(({ userId: _u, ...m }) => ({ ...m })) };
  }

  async load(userId: string, ref: { sessionId?: string; activityId?: string }) {
    if (!(await this.auth.userExists(userId))) return { sessions: [], activities: [], matches: [] };
    return this.snapshot(userId, ref);
  }

  async apply(userId: string, state: MatchState, effects: MatchEffects, now: string) {
    if (!(await this.auth.userExists(userId))) throw new MatchConflictError("user does not exist");
    const fresh: MatchState = {
      sessions: state.sessions.flatMap((s) => {
        const x = this.plans.sessionRef(userId, s.id)?.session;
        return x ? [{ id: x.id, planId: x.planId, status: x.status, revision: x.revision }] : [];
      }),
      activities: state.activities.flatMap((a) => {
        const x = this.activities.ref(userId, a.id);
        return x ? [{ id: x.id, disposition: x.disposition, revision: x.revision }] : [];
      }),
      matches: this.rows
        .filter((r) => r.userId === userId && (state.sessions.some((s) => s.id === r.sessionId) || state.activities.some((a) => a.id === r.activityId)))
        .map(({ userId: _u, ...m }) => ({ ...m })),
    };
    const key = (s: MatchState) => JSON.stringify([s.sessions, s.activities, [...s.matches].sort((a, b) => (a.sessionId < b.sessionId ? -1 : 1))]);
    if (key(fresh) !== key(state)) throw new MatchConflictError("changed since it was read");

    this.rows = this.rows.filter((r) => !(r.userId === userId && effects.removeMatches.includes(r.sessionId)));
    if (effects.putMatch) {
      const { sessionId, activityId } = effects.putMatch;
      // The table's UNIQUE (session_id) and UNIQUE (activity_id).
      if (this.rows.some((r) => r.sessionId === sessionId || r.activityId === activityId)) throw new Error("match already exists");
      this.rows.push({ ...effects.putMatch, userId });
    }
    for (const s of effects.sessions) {
      const found = this.plans.sessionRef(userId, s.id)!;
      found.session.status = s.status;
      found.session.revision += 1;
      found.session.updatedAt = now;
      found.entry.plan.contentRevision += 1;
    }
    for (const a of effects.activities) {
      const x = this.activities.ref(userId, a.id)!;
      x.disposition = a.disposition;
      x.revision += 1;
      x.updatedAt = now;
    }
  }

  async forActivities(userId: string, activityIds: string[]) {
    if (!(await this.auth.userExists(userId))) return [];
    return this.rows
      .filter((r) => r.userId === userId && activityIds.includes(r.activityId) && this.plans.sessionRef(userId, r.sessionId))
      .map(({ userId: _u, ...m }) => ({ ...m }));
  }
}

export class MemoryRateLimiter implements RateLimiter {
  private windows = new Map<string, { start: number; count: number }>();

  async hit(key: string, limit: number, windowSec: number, now: Date) {
    const nowSec = Math.floor(now.getTime() / 1000);
    const start = nowSec - (nowSec % windowSec);
    const current = this.windows.get(key);
    const window = current && current.start === start ? current : { start, count: 0 };
    window.count += 1;
    this.windows.set(key, window);
    return { allowed: window.count <= limit, retryAfterSec: Math.max(1, start + windowSec - nowSec) };
  }
}

export function memoryDeps(overrides: Partial<Deps> = {}): Deps {
  const auth = overrides.auth ?? new MemoryAuthStore();
  const plans = new MemoryPlanStore(auth);
  const activities = new MemoryActivityStore(auth);
  return {
    clock: systemClock,
    health: new MemoryHealthProbe(),
    auth,
    profiles: new MemoryProfileStore(auth),
    plans,
    activities,
    matches: new MemoryMatchStore(auth, plans, activities),
    email: new MemoryEmailSender(),
    rateLimiter: new MemoryRateLimiter(),
    ids: webIdSource,
    authConfig: { jwtSecret: "dev-only-secret-change-me-dev-only-secret" },
    ...overrides,
  };
}
