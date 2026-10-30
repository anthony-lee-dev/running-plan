import type { Disposition, StoredActivity, WorkoutType, ActivitySource } from "../../domain/activities";
import type { ActivityQuery, ActivityStore } from "../../ports";

interface Row {
  id: string;
  source: ActivitySource;
  external_id: string;
  source_app: string | null;
  workout_type: WorkoutType;
  started_at: string;
  local_date: string;
  duration_sec: number;
  distance_m: number | null;
  avg_heart_rate: number | null;
  max_heart_rate: number | null;
  avg_cadence: number | null;
  elevation_gain_m: number | null;
  disposition: Disposition;
  imported_at: string;
  revision: number;
  updated_at: string;
}

const optional = <K extends string>(key: K, value: string | number | null) => (value === null ? {} : ({ [key]: value } as Record<K, string | number>));

function toActivity(r: Row): StoredActivity {
  return {
    id: r.id,
    source: r.source,
    externalId: r.external_id,
    ...optional("sourceApp", r.source_app),
    workoutType: r.workout_type,
    startedAt: r.started_at,
    localDate: r.local_date,
    durationSec: r.duration_sec,
    ...optional("distanceM", r.distance_m),
    ...optional("avgHeartRate", r.avg_heart_rate),
    ...optional("maxHeartRate", r.max_heart_rate),
    ...optional("avgCadence", r.avg_cadence),
    ...optional("elevationGainM", r.elevation_gain_m),
    disposition: r.disposition,
    importedAt: r.imported_at,
    revision: r.revision,
    updatedAt: r.updated_at,
  } as StoredActivity;
}

const values = (a: StoredActivity) => [
  a.source, a.externalId, a.sourceApp ?? null, a.workoutType, a.startedAt, a.localDate, a.durationSec, a.distanceM ?? null,
  a.avgHeartRate ?? null, a.maxHeartRate ?? null, a.avgCadence ?? null, a.elevationGainM ?? null, a.disposition, a.revision, a.updatedAt,
];

const ORDER = "ORDER BY local_date DESC, started_at DESC, id DESC";

/** Activities in D1. An import is one read and one batch, so even 200 activities stay well inside the query limit. */
export class D1ActivityStore implements ActivityStore {
  constructor(private readonly db: D1Database) {}

  async inDateRange(userId: string, from: string, to: string) {
    const { results } = await this.db
      .prepare(`SELECT * FROM activities WHERE user_id = ? AND deleted_at IS NULL AND local_date BETWEEN ? AND ? ${ORDER}`)
      .bind(userId, from, to)
      .all<Row>();
    return results.map(toActivity);
  }

  async applyImport(userId: string, creates: StoredActivity[], updates: StoredActivity[]) {
    const statements = [
      // A source id seen outside the read window would hit the unique key; skipping it keeps the batch whole.
      ...creates.map((a) =>
        this.db
          .prepare(
            `INSERT INTO activities (source, external_id, source_app, workout_type, started_at, local_date, duration_sec, distance_m,
               avg_heart_rate, max_heart_rate, avg_cadence, elevation_gain_m, disposition, revision, updated_at, id, user_id, imported_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING`,
          )
          .bind(...values(a), a.id, userId, a.importedAt),
      ),
      ...updates.map((a) =>
        this.db
          .prepare(
            `UPDATE OR IGNORE activities SET source = ?, external_id = ?, source_app = ?, workout_type = ?, started_at = ?, local_date = ?,
               duration_sec = ?, distance_m = ?, avg_heart_rate = ?, max_heart_rate = ?, avg_cadence = ?, elevation_gain_m = ?,
               disposition = ?, revision = ?, updated_at = ?
             WHERE id = ? AND user_id = ?`,
          )
          .bind(...values(a), a.id, userId),
      ),
    ];
    if (statements.length > 0) await this.db.batch(statements);
  }

  async list(userId: string, query: ActivityQuery) {
    const where = ["user_id = ?", "deleted_at IS NULL"];
    const binds: unknown[] = [userId];
    if (query.from !== undefined) (where.push("local_date >= ?"), binds.push(query.from));
    if (query.to !== undefined) (where.push("local_date <= ?"), binds.push(query.to));
    if (query.inbox) where.push("disposition = 'inbox'");
    if (query.after) (where.push("(local_date, started_at, id) < (?, ?, ?)"), binds.push(query.after.localDate, query.after.startedAt, query.after.id));
    const { results } = await this.db
      .prepare(`SELECT * FROM activities WHERE ${where.join(" AND ")} ${ORDER} LIMIT ?`)
      .bind(...binds, query.limit)
      .all<Row>();
    return results.map(toActivity);
  }
}
