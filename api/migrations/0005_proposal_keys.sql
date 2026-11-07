-- The proposal engine's stable key for an adjustment (for example `missed_key:<session id>`), so a proposal that was
-- dismissed or accepted, or is still pending, is not made again while the facts behind it stay the same. Null for an
-- interview re-run, which is only ever made on request. Portable SQL.
ALTER TABLE proposals ADD COLUMN draft_key TEXT;
CREATE INDEX proposals_plan_key ON proposals (plan_id, draft_key);
