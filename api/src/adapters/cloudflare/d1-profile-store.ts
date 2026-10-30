import type { Profile, ProfileFields, ReviewFrequency, TargetDisplay, Weekday } from "../../domain/profile";
import type { ProfileStore } from "../../ports";

interface Row {
  target_display: TargetDisplay;
  paces: string;
  heart_rate: string;
  scheduling: string;
  review_frequency: ReviewFrequency;
  review_day: Weekday | null;
  revision: number;
  updated_at: string;
}

export class D1ProfileStore implements ProfileStore {
  constructor(private readonly db: D1Database) {}

  async get(userId: string): Promise<Profile | undefined> {
    const row = await this.db.prepare("SELECT * FROM profiles WHERE user_id = ?").bind(userId).first<Row>();
    if (!row) return undefined;
    return {
      targetDisplay: row.target_display,
      paces: JSON.parse(row.paces),
      heartRate: JSON.parse(row.heart_rate),
      scheduling: JSON.parse(row.scheduling),
      review: { frequency: row.review_frequency, ...(row.review_day ? { day: row.review_day } : {}) },
      revision: row.revision,
      updatedAt: row.updated_at,
    };
  }

  async save(userId: string, baseRevision: number, fields: ProfileFields, now: string) {
    const values = [
      fields.targetDisplay,
      JSON.stringify(fields.paces),
      JSON.stringify(fields.heartRate),
      JSON.stringify(fields.scheduling),
      fields.review.frequency,
      fields.review.day ?? null,
    ];
    const next = baseRevision + 1;
    // Nothing is stored until the first save, so the default revision 1 means "insert"; anything else "update".
    let result: D1Result;
    try {
      result =
      baseRevision === 1
        ? await this.db
            .prepare(
              `INSERT INTO profiles (user_id, target_display, paces, heart_rate, scheduling, review_frequency, review_day, revision, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (user_id) DO NOTHING`,
            )
            .bind(userId, ...values, next, now)
            .run()
        : await this.db
            .prepare(
              `UPDATE profiles SET target_display = ?, paces = ?, heart_rate = ?, scheduling = ?, review_frequency = ?,
                 review_day = ?, revision = ?, updated_at = ? WHERE user_id = ? AND revision = ?`,
            )
            .bind(...values, next, now, userId, baseRevision)
            .run();
    } catch (error) {
      // The account was deleted after the caller signed in: the foreign key refuses the insert.
      if (!(await this.db.prepare("SELECT 1 AS ok FROM users WHERE id = ?").bind(userId).first())) {
        return { ok: false as const, currentRevision: 1 };
      }
      throw error;
    }
    if (result.meta.changes === 0) {
      const current = await this.get(userId);
      return { ok: false as const, currentRevision: current?.revision ?? 1 };
    }
    return { ok: true as const, profile: { ...structuredClone(fields), revision: next, updatedAt: now } };
  }
}
