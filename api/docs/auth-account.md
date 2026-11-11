# Sign-in, tokens, account export

Part of the API guide (`api/CLAUDE.md` has the index). Read this before changing `src/domain/auth.ts`, `jwt.ts`, `src/http/auth.ts`, `account.ts`.

- Auth (task 2.4): email one-time code, HS256 access tokens (15 min), rotating refresh tokens (60 days, reuse of a
  rotated token revokes its family), scopes by client type. Codes and refresh tokens are stored only as HMAC
  hashes. The Workers entry needs the secrets `JWT_SECRET` (32+ characters; the entry refuses to run without it),
  the `EMAIL` send binding and `MAIL_FROM`; without them it refuses to run unless `ALLOW_LOG_EMAIL=1` (local dev only: codes
  are printed). Put local values in `api/.dev.vars` (gitignored). Only `cf-connecting-ip` is trusted for rate limits.
  Access tokens stay valid until they expire (15 minutes) after their refresh family is revoked; account delete
  takes effect at once because each request checks the user still exists. Production secrets are set by the human with `npx wrangler secret put <NAME>`.
- Account export (task 2.16, `POST /v1/account/export`; the spec says POST, the issue text said GET): `AccountExportStore.read`
  returns flat live lists and `src/http/account.ts` shapes them with the same views as the plan and activity routes (`planDetail`,
  `activityView`). On D1 it is one `db.batch` of eight selects bound to the user alone, so the data read counts as one query however
  much the account holds (about four with the token check, rate limit and profile read); keep it that way (no per-plan lookups). Left out: tombstones, and everything under a deleted plan
  (its sessions are not tombstoned, so each table joins the plan and requires it live), check-ins and matches of deleted
  sessions. Activities are the user's own data and stay when their plan goes. Limited to 5 an hour per account, response
  `Cache-Control: no-store`. Proposals are exported in the spec's `Proposal` shape (live ones of live plans; the engine's key and the revision stay out), by the D1 store and the memory store alike.
