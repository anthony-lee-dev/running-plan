import { env } from "cloudflare:workers";
import { applyD1Migrations } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";

const SYNCED = ["plans", "sessions", "checkins", "activities", "proposals"];
const NOW = "2026-10-28T09:00:00.000Z";
const USER = "00000000-0000-4000-8000-000000000001";
const PLAN = "00000000-0000-4000-8000-0000000000a1";
const SESSION = "00000000-0000-4000-8000-0000000000b1";
const ACTIVITY = "00000000-0000-4000-8000-0000000000c1";

const db = () => env.DB;

async function run(sql: string, ...binds: unknown[]) {
  return db()
    .prepare(sql)
    .bind(...binds)
    .run();
}

async function insertUser(id = USER, email = "runner@example.com") {
  await run("INSERT INTO users (id, email, created_at) VALUES (?, ?, ?)", id, email, NOW);
}

async function insertPlan(id = PLAN, userId = USER) {
  await run(
    `INSERT INTO plans (id, user_id, goal_type, start_date, week_count, source, adaptive, revision, content_revision, updated_at)
     VALUES (?, ?, '5k', '2026-11-02', 8, 'rules', 1, 1, 1, ?)`,
    id,
    userId,
    NOW,
  );
}

async function insertSession(id = SESSION, planId = PLAN, date = "2026-11-02", type = "easy") {
  await run(
    `INSERT INTO sessions (id, plan_id, user_id, date, type, status, owner, steps, revision, updated_at)
     VALUES (?, ?, ?, ?, ?, 'planned', 'system', '[]', 1, ?)`,
    id,
    planId,
    USER,
    date,
    type,
    NOW,
  );
}

async function insertActivity(id = ACTIVITY, externalId = "hk-1") {
  await run(
    `INSERT INTO activities (id, user_id, source, external_id, workout_type, started_at, local_date, duration_sec, disposition, revision, updated_at, imported_at)
     VALUES (?, ?, 'apple_health', ?, 'running', ?, '2026-11-02', 1800, 'inbox', 1, ?, ?)`,
    id,
    USER,
    externalId,
    "2026-11-02T07:00:00+01:00",
    NOW,
    NOW,
  );
}

beforeAll(async () => {
  await applyD1Migrations(db(), env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  // Foreign keys cascade from users, so this clears everything.
  await run("DELETE FROM users");
});

describe("D1 schema", () => {
  it("creates a table for every §5 entity", async () => {
    const { results } = await db()
      .prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
      .all<{ name: string }>();
    const names = results.map((r) => r.name);
    for (const t of [
      "users",
      "plans",
      "plan_weeks",
      "sessions",
      "checkins",
      "activities",
      "matches",
      "proposals",
      "profiles",
    ]) {
      expect(names).toContain(t);
    }
  });

  it.each(SYNCED)("%s carries revision, updated_at and a deleted_at tombstone", async (table) => {
    const { results } = await db().prepare(`PRAGMA table_info(${table})`).all<{ name: string; notnull: number }>();
    const cols = new Map(results.map((r) => [r.name, r.notnull]));
    expect(cols.get("id")).toBeDefined();
    expect(cols.get("revision")).toBe(1);
    expect(cols.get("updated_at")).toBe(1);
    expect(cols.has("deleted_at")).toBe(true);
    expect(cols.get("deleted_at")).toBe(0);
  });

  it.each(SYNCED)("%s has an index for the per-user sync cursor", async (table) => {
    const { results } = await db().prepare(`PRAGMA index_list(${table})`).all<{ name: string }>();
    const covered = await Promise.all(
      results.map(async ({ name }) => {
        const { results: cols } = await db().prepare(`PRAGMA index_info(${name})`).all<{ name: string }>();
        return cols.map((c) => c.name).join(",");
      }),
    );
    expect(covered).toContain("user_id,updated_at");
  });

  it("rejects a revision below 1", async () => {
    await insertUser();
    await expect(
      run(
        `INSERT INTO plans (id, user_id, goal_type, start_date, week_count, source, adaptive, revision, content_revision, updated_at)
         VALUES (?, ?, '5k', '2026-11-02', 8, 'rules', 1, 0, 1, ?)`,
        PLAN,
        USER,
        NOW,
      ),
    ).rejects.toThrow();
  });

  it("stores a plan and soft-deletes it with a tombstone", async () => {
    await insertUser();
    await insertPlan();
    await run("UPDATE plans SET deleted_at = ?, revision = revision + 1 WHERE id = ?", NOW, PLAN);
    const row = await db().prepare("SELECT revision, deleted_at FROM plans WHERE id = ?").bind(PLAN).first();
    expect(row).toEqual({ revision: 2, deleted_at: NOW });
  });

  it("keeps local dates as YYYY-MM-DD text", async () => {
    await insertUser();
    await insertPlan();
    await expect(insertSession(SESSION, PLAN, "2026-11-2")).rejects.toThrow();
    await expect(insertSession(SESSION, PLAN, "02/11/2026")).rejects.toThrow();
    await insertSession(SESSION, PLAN, "2026-11-02");
  });

  it("rejects values outside the spec enums", async () => {
    await insertUser();
    await insertPlan();
    await expect(insertSession(SESSION, PLAN, "2026-11-02", "sprint")).rejects.toThrow();
    await expect(run("UPDATE plans SET source = 'magic' WHERE id = ?", PLAN)).rejects.toThrow();
    await expect(run("UPDATE plans SET goal_type = 'marathon' WHERE id = ?", PLAN)).rejects.toThrow();
  });

  it("limits plans to 52 weeks", async () => {
    await insertUser();
    await insertPlan();
    await expect(run("UPDATE plans SET week_count = 53 WHERE id = ?", PLAN)).rejects.toThrow();
    await expect(run("UPDATE plans SET week_count = 0 WHERE id = ?", PLAN)).rejects.toThrow();
  });

  it("refuses a session for a plan that does not exist", async () => {
    await insertUser();
    await expect(insertSession()).rejects.toThrow();
  });

  it("deletes everything a user owns when the account is hard-deleted", async () => {
    await insertUser();
    await insertPlan();
    await insertSession();
    await run("INSERT INTO plan_weeks (plan_id, idx, phase) VALUES (?, 0, 'base')", PLAN);
    await insertActivity();
    await run(
      "INSERT INTO matches (session_id, activity_id, user_id, status, updated_at) VALUES (?, ?, ?, 'confirmed', ?)",
      SESSION,
      ACTIVITY,
      USER,
      NOW,
    );
    await run("DELETE FROM users WHERE id = ?", USER);
    for (const t of ["plans", "plan_weeks", "sessions", "activities", "matches"]) {
      const row = await db().prepare(`SELECT COUNT(*) AS n FROM ${t}`).first<{ n: number }>();
      expect(row?.n, t).toBe(0);
    }
  });

  it("keeps email unique per user", async () => {
    await insertUser();
    await expect(insertUser("00000000-0000-4000-8000-000000000002")).rejects.toThrow();
  });

  it("dedupes activities on source and external id per user", async () => {
    await insertUser();
    await insertActivity();
    await expect(insertActivity("00000000-0000-4000-8000-0000000000c2")).rejects.toThrow();
    await insertActivity("00000000-0000-4000-8000-0000000000c3", "hk-2");
  });

  it("matches one activity to at most one session and a session to at most one activity", async () => {
    await insertUser();
    await insertPlan();
    await insertSession();
    await insertSession("00000000-0000-4000-8000-0000000000b2", PLAN, "2026-11-03");
    await insertActivity();
    await insertActivity("00000000-0000-4000-8000-0000000000c2", "hk-2");
    const match = (s: string, a: string) =>
      run(
        "INSERT INTO matches (session_id, activity_id, user_id, status, updated_at) VALUES (?, ?, ?, 'suggested', ?)",
        s,
        a,
        USER,
        NOW,
      );
    await match(SESSION, ACTIVITY);
    await expect(match(SESSION, "00000000-0000-4000-8000-0000000000c2")).rejects.toThrow();
    await expect(match("00000000-0000-4000-8000-0000000000b2", ACTIVITY)).rejects.toThrow();
  });

  it("constrains check-in feel, effort and timing", async () => {
    await insertUser();
    await insertPlan();
    await insertSession();
    const checkin = (id: string, when: string, feel: number, effort: number | null) =>
      run(
        `INSERT INTO checkins (id, session_id, user_id, "when", feel, effort_felt, pain, revision, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, 0, 1, ?)`,
        id,
        SESSION,
        USER,
        when,
        feel,
        effort,
        NOW,
      );
    await checkin("00000000-0000-4000-8000-0000000000d1", "after", 3, 6);
    await expect(checkin("00000000-0000-4000-8000-0000000000d2", "after", 6, null)).rejects.toThrow();
    await expect(checkin("00000000-0000-4000-8000-0000000000d3", "after", 3, 11)).rejects.toThrow();
    await expect(checkin("00000000-0000-4000-8000-0000000000d4", "during", 3, null)).rejects.toThrow();
  });

  it("records the plan revision a proposal was based on", async () => {
    await insertUser();
    await insertPlan();
    const proposal = (status: string) =>
      run(
        `INSERT INTO proposals (id, plan_id, user_id, base_content_revision, kind, creator_type, creator_version, reason, urgent, changes, status, revision, created_at, updated_at)
         VALUES (?, ?, ?, 1, 'adjustment', 'rules', '1.0.0', 'Missed key session', 0, '[]', ?, 1, ?, ?)`,
        "00000000-0000-4000-8000-0000000000e1",
        PLAN,
        USER,
        status,
        NOW,
        NOW,
      );
    await expect(proposal("approved")).rejects.toThrow();
    await proposal("pending");
  });

  it("keeps one profile per user with the spec defaults", async () => {
    await insertUser();
    await run("INSERT INTO profiles (user_id, updated_at) VALUES (?, ?)", USER, NOW);
    await expect(run("INSERT INTO profiles (user_id, updated_at) VALUES (?, ?)", USER, NOW)).rejects.toThrow();
    const row = await db()
      .prepare("SELECT target_display, review_frequency, revision FROM profiles WHERE user_id = ?")
      .bind(USER)
      .first();
    expect(row).toEqual({ target_display: "pace", review_frequency: "weekly_plus_urgent", revision: 1 });
    await expect(run("UPDATE profiles SET review_day = 'someday' WHERE user_id = ?", USER)).rejects.toThrow();
    await run("UPDATE profiles SET review_day = 'sun' WHERE user_id = ?", USER);
  });
});
