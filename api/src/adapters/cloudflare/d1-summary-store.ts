import type { StoredSummary, SummaryReason, SummaryStore } from "../../ports";

interface Row {
  activity_id: string;
  facts_hash: string;
  prompt_version: string;
  model: string;
  source: "ai" | "template";
  reason: SummaryReason | null;
  text: string;
  created_at: string;
}

/** Run summaries in D1. A write names the user, so it lands only on one of their own activities. */
export class D1SummaryStore implements SummaryStore {
  constructor(private readonly db: D1Database) {}

  async get(userId: string, activityId: string): Promise<StoredSummary | undefined> {
    const row = await this.db.prepare("SELECT * FROM activity_summaries WHERE activity_id = ? AND user_id = ?").bind(activityId, userId).first<Row>();
    if (!row) return undefined;
    return {
      activityId: row.activity_id,
      factsHash: row.facts_hash,
      promptVersion: row.prompt_version,
      model: row.model,
      source: row.source,
      ...(row.reason ? { reason: row.reason } : {}),
      text: row.text,
      createdAt: row.created_at,
    };
  }

  async put(userId: string, s: StoredSummary): Promise<void> {
    await this.db
      .prepare(
        `INSERT INTO activity_summaries (activity_id, user_id, facts_hash, prompt_version, model, source, reason, text, created_at)
         SELECT a.id, a.user_id, ?, ?, ?, ?, ?, ?, ? FROM activities a WHERE a.id = ? AND a.user_id = ?
         ON CONFLICT (activity_id) DO UPDATE SET facts_hash = excluded.facts_hash, prompt_version = excluded.prompt_version,
           model = excluded.model, source = excluded.source, reason = excluded.reason, text = excluded.text, created_at = excluded.created_at`,
      )
      .bind(s.factsHash, s.promptVersion, s.model, s.source, s.reason ?? null, s.text, s.createdAt, s.activityId, userId)
      .run();
  }
}
