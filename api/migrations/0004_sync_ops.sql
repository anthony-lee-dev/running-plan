-- Offline edit queue (POST /v1/sync): one row per applied operation, keyed by the client's idempotency key, so a
-- retried batch never applies twice. Only applied operations are kept: a conflict or rejection is evaluated afresh
-- when resent. op_hash fingerprints the operation, so a key reused for a different edit is told apart from a retry.
-- Portable SQL; deleting a user removes their rows with the account.
CREATE TABLE sync_ops (
  user_id         TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  idempotency_key TEXT NOT NULL,
  op_hash         TEXT NOT NULL,
  revision        INTEGER NOT NULL CHECK (revision >= 1),
  created_at      TEXT NOT NULL,
  PRIMARY KEY (user_id, idempotency_key)
);
