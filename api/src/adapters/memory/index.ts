import type {
  AuthStore,
  Clock,
  CodeRecord,
  Deps,
  EmailSender,
  HealthProbe,
  IdSource,
  RateLimiter,
  RefreshRecord,
  UserRecord,
} from "../../ports";

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
  return {
    clock: systemClock,
    health: new MemoryHealthProbe(),
    auth: new MemoryAuthStore(),
    email: new MemoryEmailSender(),
    rateLimiter: new MemoryRateLimiter(),
    ids: webIdSource,
    authConfig: { jwtSecret: "dev-only-secret-change-me-dev-only-secret" },
    ...overrides,
  };
}
