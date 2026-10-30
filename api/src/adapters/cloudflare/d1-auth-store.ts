import type { AuthStore, ClientType, CodeRecord, RefreshRecord, Scope, UserRecord } from "../../ports";

interface RefreshRow {
  id: string;
  user_id: string;
  family_id: string;
  token_hash: string;
  client_type: ClientType;
  scopes: string;
  created_at: string;
  expires_at: string;
  rotated_at: string | null;
  revoked_at: string | null;
}

export class D1AuthStore implements AuthStore {
  constructor(private readonly db: D1Database) {}

  async saveCode(email: string, codeHash: string, expiresAt: string, now: string): Promise<void> {
    await this.db
      .prepare(
        `INSERT INTO email_codes (email, code_hash, expires_at, attempts, created_at) VALUES (?, ?, ?, 0, ?)
         ON CONFLICT (email) DO UPDATE SET code_hash = excluded.code_hash, expires_at = excluded.expires_at,
           attempts = 0, created_at = excluded.created_at`,
      )
      .bind(email, codeHash, expiresAt, now)
      .run();
  }

  async getCode(email: string): Promise<CodeRecord | undefined> {
    const row = await this.db
      .prepare("SELECT code_hash, expires_at, attempts FROM email_codes WHERE email = ?")
      .bind(email)
      .first<{ code_hash: string; expires_at: string; attempts: number }>();
    return row ? { codeHash: row.code_hash, expiresAt: row.expires_at, attempts: row.attempts } : undefined;
  }

  async useCodeAttempt(email: string, max: number): Promise<boolean> {
    const result = await this.db
      .prepare("UPDATE email_codes SET attempts = attempts + 1 WHERE email = ? AND attempts < ?")
      .bind(email, max)
      .run();
    return result.meta.changes > 0;
  }

  async deleteCode(email: string): Promise<boolean> {
    const result = await this.db.prepare("DELETE FROM email_codes WHERE email = ?").bind(email).run();
    return result.meta.changes > 0;
  }

  async findOrCreateUser(email: string, newId: string, now: string): Promise<{ user: UserRecord; created: boolean }> {
    const inserted = await this.db
      .prepare("INSERT INTO users (id, email, created_at) VALUES (?, ?, ?) ON CONFLICT (email) DO NOTHING")
      .bind(newId, email, now)
      .run();
    const row = await this.db
      .prepare("SELECT id, email, created_at FROM users WHERE email = ?")
      .bind(email)
      .first<{ id: string; email: string; created_at: string }>();
    if (!row) throw new Error("user missing after insert");
    return { user: { id: row.id, email: row.email, createdAt: row.created_at }, created: inserted.meta.changes > 0 };
  }

  async userExists(id: string): Promise<boolean> {
    return (await this.db.prepare("SELECT 1 AS ok FROM users WHERE id = ?").bind(id).first()) !== null;
  }

  async saveRefresh(r: RefreshRecord): Promise<void> {
    await this.db
      .prepare(
        `INSERT INTO refresh_tokens (id, user_id, family_id, token_hash, client_type, scopes, created_at, expires_at, rotated_at, revoked_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(r.id, r.userId, r.familyId, r.tokenHash, r.clientType, JSON.stringify(r.scopes), r.createdAt, r.expiresAt, r.rotatedAt, r.revokedAt)
      .run();
  }

  async findRefresh(tokenHash: string): Promise<RefreshRecord | undefined> {
    const row = await this.db.prepare("SELECT * FROM refresh_tokens WHERE token_hash = ?").bind(tokenHash).first<RefreshRow>();
    if (!row) return undefined;
    return {
      id: row.id,
      userId: row.user_id,
      familyId: row.family_id,
      tokenHash: row.token_hash,
      clientType: row.client_type,
      scopes: JSON.parse(row.scopes) as Scope[],
      createdAt: row.created_at,
      expiresAt: row.expires_at,
      rotatedAt: row.rotated_at,
      revokedAt: row.revoked_at,
    };
  }

  async markRefreshRotated(id: string, at: string): Promise<boolean> {
    const result = await this.db
      .prepare("UPDATE refresh_tokens SET rotated_at = ? WHERE id = ? AND rotated_at IS NULL AND revoked_at IS NULL")
      .bind(at, id)
      .run();
    return result.meta.changes > 0;
  }

  async revokeFamily(familyId: string, at: string): Promise<void> {
    await this.db
      .prepare("UPDATE refresh_tokens SET revoked_at = ? WHERE family_id = ? AND revoked_at IS NULL")
      .bind(at, familyId)
      .run();
  }

  async deleteUser(id: string): Promise<void> {
    // Foreign keys cascade to refresh tokens, plans, sessions and the rest.
    await this.db.prepare("DELETE FROM users WHERE id = ?").bind(id).run();
  }
}
