import type { RateLimiter } from "../../ports";

/** Fixed-window counter in D1: one upsert per hit. */
export class D1RateLimiter implements RateLimiter {
  constructor(private readonly db: D1Database) {}

  async hit(key: string, limit: number, windowSec: number, now: Date) {
    const nowSec = Math.floor(now.getTime() / 1000);
    const start = nowSec - (nowSec % windowSec);
    const row = await this.db
      .prepare(
        `INSERT INTO rate_limits (key, window_start, count) VALUES (?, ?, 1)
         ON CONFLICT (key) DO UPDATE SET
           count = CASE WHEN window_start = excluded.window_start THEN count + 1 ELSE 1 END,
           window_start = excluded.window_start
         RETURNING count`,
      )
      .bind(key, start)
      .first<{ count: number }>();
    return { allowed: (row?.count ?? 1) <= limit, retryAfterSec: Math.max(1, start + windowSec - nowSec) };
  }
}
