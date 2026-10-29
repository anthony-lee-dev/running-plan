-- Initial schema from the §5 data model (system design) and spec/openapi.yaml.
-- Portable SQL: TEXT ids (client UUIDs), TEXT ISO-8601 timestamps, TEXT YYYY-MM-DD local dates,
-- integer metres and seconds, CHECK constraints for enums, JSON kept as TEXT and never queried inside.
-- Synced entities (plans, sessions, checkins, activities, proposals) carry revision, updated_at and a
-- deleted_at tombstone. Date GLOBs check the shape only; calendar validity belongs in the domain code.
-- plan_weeks ride on their plan (sync carries week notes and phases in the plan fields) and a match rides on its
-- session and activity, so neither has its own revision or tombstone. Deleting a user removes everything they own (account delete, §10).

CREATE TABLE users (
  id         TEXT PRIMARY KEY,
  email      TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL
);

CREATE TABLE plans (
  id                TEXT PRIMARY KEY,
  user_id           TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  goal_type         TEXT NOT NULL CHECK (goal_type IN ('5k', '10k', 'half_marathon', 'custom', 'none')),
  goal_label        TEXT,
  goal_date         TEXT CHECK (goal_date IS NULL OR goal_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  goal_target_sec   INTEGER CHECK (goal_target_sec IS NULL OR goal_target_sec BETWEEN 60 AND 86400),
  start_date        TEXT NOT NULL CHECK (start_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  week_count        INTEGER NOT NULL CHECK (week_count BETWEEN 1 AND 52),
  source            TEXT NOT NULL CHECK (source IN ('blank', 'rules', 'ai')),
  engine_preset_id  TEXT,
  engine_version    TEXT,
  engine_interview  TEXT,
  adaptive          INTEGER NOT NULL CHECK (adaptive IN (0, 1)),
  revision          INTEGER NOT NULL CHECK (revision >= 1),
  -- Moves on any change to the plan or its sessions; proposals go stale when it moves.
  content_revision  INTEGER NOT NULL CHECK (content_revision >= 1),
  updated_at        TEXT NOT NULL,
  deleted_at        TEXT
);
CREATE INDEX plans_user_updated ON plans (user_id, updated_at);

CREATE TABLE plan_weeks (
  plan_id TEXT NOT NULL REFERENCES plans (id) ON DELETE CASCADE,
  idx     INTEGER NOT NULL CHECK (idx BETWEEN 0 AND 51),
  phase   TEXT CHECK (phase IS NULL OR phase IN ('base', 'build', 'peak', 'taper')),
  notes   TEXT,
  PRIMARY KEY (plan_id, idx)
);

CREATE TABLE sessions (
  id           TEXT PRIMARY KEY,
  plan_id      TEXT NOT NULL REFERENCES plans (id) ON DELETE CASCADE,
  user_id      TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  date         TEXT NOT NULL CHECK (date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  type         TEXT NOT NULL CHECK (type IN ('easy', 'long', 'intervals', 'tempo', 'strength', 'rest', 'custom')),
  title        TEXT,
  is_key       INTEGER NOT NULL DEFAULT 0 CHECK (is_key IN (0, 1)),
  status       TEXT NOT NULL DEFAULT 'planned' CHECK (status IN ('planned', 'done', 'skipped')),
  owner        TEXT NOT NULL DEFAULT 'system' CHECK (owner IN ('system', 'user')),
  -- Step tree as JSON. Totals are derived from it, never stored.
  steps        TEXT NOT NULL DEFAULT '[]',
  custom       TEXT,
  notes        TEXT,
  revision     INTEGER NOT NULL CHECK (revision >= 1),
  updated_at   TEXT NOT NULL,
  deleted_at   TEXT
);
CREATE INDEX sessions_user_updated ON sessions (user_id, updated_at);
CREATE INDEX sessions_plan_date ON sessions (plan_id, date);

CREATE TABLE activities (
  id               TEXT PRIMARY KEY,
  user_id          TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  source           TEXT NOT NULL CHECK (source IN ('apple_health', 'manual')),
  external_id      TEXT NOT NULL,
  source_app       TEXT,
  workout_type     TEXT NOT NULL CHECK (workout_type IN ('running', 'strength', 'cycling', 'swimming', 'walking', 'other')),
  started_at       TEXT NOT NULL,
  local_date       TEXT NOT NULL CHECK (local_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
  duration_sec     INTEGER NOT NULL CHECK (duration_sec BETWEEN 1 AND 86400),
  distance_m       INTEGER CHECK (distance_m IS NULL OR distance_m BETWEEN 0 AND 400000),
  avg_heart_rate   INTEGER CHECK (avg_heart_rate IS NULL OR avg_heart_rate BETWEEN 30 AND 250),
  max_heart_rate   INTEGER CHECK (max_heart_rate IS NULL OR max_heart_rate BETWEEN 30 AND 250),
  avg_cadence      INTEGER CHECK (avg_cadence IS NULL OR avg_cadence BETWEEN 0 AND 300),
  elevation_gain_m INTEGER CHECK (elevation_gain_m IS NULL OR elevation_gain_m BETWEEN 0 AND 10000),
  disposition      TEXT NOT NULL DEFAULT 'inbox' CHECK (disposition IN ('inbox', 'matched', 'extra', 'ignored')),
  imported_at      TEXT NOT NULL,
  revision         INTEGER NOT NULL CHECK (revision >= 1),
  updated_at       TEXT NOT NULL,
  deleted_at       TEXT,
  -- Dedupe key from the source; the API also dedupes on start, duration and distance.
  UNIQUE (user_id, source, external_id)
);
CREATE INDEX activities_user_updated ON activities (user_id, updated_at);
CREATE INDEX activities_user_local_date ON activities (user_id, local_date);

-- Links an activity to a session. Plan-versus-actual deltas are derived, not stored.
CREATE TABLE matches (
  session_id  TEXT NOT NULL UNIQUE REFERENCES sessions (id) ON DELETE CASCADE,
  activity_id TEXT NOT NULL UNIQUE REFERENCES activities (id) ON DELETE CASCADE,
  user_id     TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  status      TEXT NOT NULL CHECK (status IN ('suggested', 'confirmed')),
  updated_at  TEXT NOT NULL,
  PRIMARY KEY (session_id, activity_id)
);

CREATE TABLE checkins (
  id          TEXT PRIMARY KEY,
  session_id  TEXT NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
  user_id     TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  "when"      TEXT NOT NULL CHECK ("when" IN ('before', 'after')),
  feel        INTEGER NOT NULL CHECK (feel BETWEEN 1 AND 5),
  effort_felt INTEGER CHECK (effort_felt IS NULL OR effort_felt BETWEEN 1 AND 10),
  pain        INTEGER NOT NULL DEFAULT 0 CHECK (pain IN (0, 1)),
  note        TEXT,
  revision    INTEGER NOT NULL CHECK (revision >= 1),
  updated_at  TEXT NOT NULL,
  deleted_at  TEXT
);
CREATE INDEX checkins_user_updated ON checkins (user_id, updated_at);
CREATE INDEX checkins_session ON checkins (session_id);

CREATE TABLE proposals (
  id                    TEXT PRIMARY KEY,
  plan_id               TEXT NOT NULL REFERENCES plans (id) ON DELETE CASCADE,
  user_id               TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  -- The plan content_revision this was built on; stale once that moves.
  base_content_revision INTEGER NOT NULL CHECK (base_content_revision >= 1),
  kind                  TEXT NOT NULL CHECK (kind IN ('adjustment', 'interview_rerun')),
  creator_type          TEXT NOT NULL CHECK (creator_type IN ('rules', 'ai')),
  creator_version       TEXT NOT NULL,
  reason                TEXT NOT NULL,
  urgent                INTEGER NOT NULL DEFAULT 0 CHECK (urgent IN (0, 1)),
  changes               TEXT NOT NULL DEFAULT '[]',
  plan_changes          TEXT,
  status                TEXT NOT NULL CHECK (status IN ('pending', 'accepted', 'dismissed', 'stale')),
  resolved_at           TEXT,
  created_at            TEXT NOT NULL,
  revision              INTEGER NOT NULL CHECK (revision >= 1),
  updated_at            TEXT NOT NULL,
  deleted_at            TEXT
);
CREATE INDEX proposals_user_updated ON proposals (user_id, updated_at);
CREATE INDEX proposals_plan_status ON proposals (plan_id, status);

-- One row per user. Not a synced entity: edits are last write wins with a revision check.
CREATE TABLE profiles (
  user_id            TEXT PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
  target_display     TEXT NOT NULL DEFAULT 'pace' CHECK (target_display IN ('pace', 'heart_rate', 'effort')),
  paces              TEXT NOT NULL DEFAULT '{"source":"none"}',
  heart_rate         TEXT NOT NULL DEFAULT '{}',
  scheduling         TEXT NOT NULL DEFAULT '{}',
  review_frequency   TEXT NOT NULL DEFAULT 'weekly_plus_urgent'
                       CHECK (review_frequency IN ('weekly', 'weekly_plus_urgent', 'after_import', 'off')),
  review_day         TEXT CHECK (review_day IS NULL OR review_day IN ('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun')),
  revision           INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
  updated_at         TEXT NOT NULL
);
