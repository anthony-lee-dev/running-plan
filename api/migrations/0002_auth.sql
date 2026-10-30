-- Sign-in by emailed one-time code: codes, refresh tokens and a fixed-window rate limiter.
-- Only hashes are stored (HMAC of the code or token); never the code or token itself.

-- One live code per email. Not tied to a user: the account is created on the first successful verify.
CREATE TABLE email_codes (
  email      TEXT PRIMARY KEY,
  code_hash  TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  attempts   INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  created_at TEXT NOT NULL
);

CREATE TABLE refresh_tokens (
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  -- Every token descended from one sign-in; all revoked together when a rotated token is reused.
  family_id   TEXT NOT NULL,
  token_hash  TEXT NOT NULL UNIQUE,
  client_type TEXT NOT NULL CHECK (client_type IN ('ios', 'android', 'web')),
  scopes      TEXT NOT NULL,
  created_at  TEXT NOT NULL,
  expires_at  TEXT NOT NULL,
  rotated_at  TEXT,
  revoked_at  TEXT
);
CREATE INDEX refresh_tokens_family ON refresh_tokens (family_id);
CREATE INDEX refresh_tokens_user ON refresh_tokens (user_id);

-- Fixed-window counters. window_start is epoch seconds, so old rows are cheap to prune.
CREATE TABLE rate_limits (
  key          TEXT PRIMARY KEY,
  window_start INTEGER NOT NULL,
  count        INTEGER NOT NULL CHECK (count >= 0)
);
