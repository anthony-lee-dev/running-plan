import type { StoredCheckIn, CheckInStore } from "../../ports";

interface Row {
  id: string;
  user_id: string;
  session_id: string;
  when: "before" | "after";
  feel: number;
  effort_felt: number | null;
  pain: number;
  note: string | null;
  revision: number;
  updated_at: string;
  deleted_at: string | null;
}

const toCheckIn = (r: Row): StoredCheckIn => ({
  id: r.id,
  sessionId: r.session_id,
  when: r.when,
  feel: r.feel,
  ...(r.effort_felt === null ? {} : { effortFelt: r.effort_felt }),
  pain: r.pain === 1,
  ...(r.note === null ? {} : { note: r.note }),
  revision: r.revision,
  updatedAt: r.updated_at,
  deletedAt: r.deleted_at,
});

/** Check-ins in D1: one batch checks the session, inserts (only on a live session of the user) and reads the row back. */
export class D1CheckInStore implements CheckInStore {
  constructor(private readonly db: D1Database) {}

  async create(userId: string, c: StoredCheckIn) {
    const [live, inserted, read] = await this.db.batch([
      this.db
        .prepare("SELECT 1 FROM sessions s JOIN plans p ON p.id = s.plan_id WHERE s.id = ? AND s.deleted_at IS NULL AND p.deleted_at IS NULL AND p.user_id = ?")
        .bind(c.sessionId, userId),
      this.db
        .prepare(
          `INSERT INTO checkins (id, session_id, user_id, "when", feel, effort_felt, pain, note, revision, updated_at, deleted_at)
           SELECT ?, s.id, ?, ?, ?, ?, ?, ?, ?, ?, ? FROM sessions s JOIN plans p ON p.id = s.plan_id
           WHERE s.id = ? AND s.deleted_at IS NULL AND p.deleted_at IS NULL AND p.user_id = ?
           ON CONFLICT (id) DO NOTHING`,
        )
        .bind(c.id, userId, c.when, c.feel, c.effortFelt ?? null, c.pain ? 1 : 0, c.note ?? null, c.revision, c.updatedAt, c.deletedAt, c.sessionId, userId),
      this.db.prepare("SELECT * FROM checkins WHERE id = ?").bind(c.id),
    ]);
    const row = (read!.results as Row[])[0];
    // The session first: one that is not the user's is simply not found, whatever the id.
    if (live!.results.length === 0 || !row) return { status: "no_session" as const };
    if (inserted!.meta.changes > 0) return { status: "created" as const, checkIn: toCheckIn(row) };
    return row.user_id === userId ? { status: "exists" as const, mine: true as const, checkIn: toCheckIn(row) } : { status: "exists" as const, mine: false as const };
  }
}
