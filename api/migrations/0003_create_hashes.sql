-- Idempotent creates: repeating a create with the same id and body returns the stored entity; the same id with a
-- different body is a conflict. The hash is of the canonical request, kept so later edits do not change the answer.
ALTER TABLE plans ADD COLUMN create_hash TEXT;
ALTER TABLE sessions ADD COLUMN create_hash TEXT;
