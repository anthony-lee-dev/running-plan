-- Run summaries (issue #132): the written summary of one run. Derived data: it is rebuilt from the run, so it is not
-- synced and not in the account export; the clients fetch it. It goes with the activity (and the user) on delete.
-- `facts_hash` fingerprints the facts the text was written from: a summary is served only while it still matches.
-- `source` is 'ai' for model text that passed the checks, or 'template' for a remembered failed attempt (with its
-- `reason`), so reopening a run does not spend more model calls on data that already failed. Portable SQL.
CREATE TABLE activity_summaries (
  activity_id    TEXT PRIMARY KEY REFERENCES activities (id) ON DELETE CASCADE,
  user_id        TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  facts_hash     TEXT NOT NULL,
  prompt_version TEXT NOT NULL,
  model          TEXT NOT NULL,
  source         TEXT NOT NULL CHECK (source IN ('ai', 'template')),
  reason         TEXT,
  text           TEXT NOT NULL,
  created_at     TEXT NOT NULL
);
CREATE INDEX activity_summaries_user ON activity_summaries (user_id);

-- The per-account switch for AI run summaries (on by default).
ALTER TABLE profiles ADD COLUMN ai_summaries INTEGER NOT NULL DEFAULT 1 CHECK (ai_summaries IN (0, 1));
