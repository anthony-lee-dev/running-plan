# api

Hono on Cloudflare Workers, D1 (SQLite) for storage. Built so a move to Azure means new adapters and a new
entry file, not a rewrite.

## Structure

- `src/domain/` pure TypeScript: plan rule engine, pace maths, date rules. No I/O, no framework imports.
- `src/ports/` interfaces the app depends on (repositories, clock, health probe).
- `src/adapters/cloudflare/` D1/KV/R2 implementations. The only folder allowed to touch Cloudflare APIs.
- `src/adapters/memory/` in-memory implementations used by tests and the Node entry.
- `src/http/` Hono routes; they call domain code through ports.
- `src/app.ts` builds the app from its dependencies. `src/index.ts` is the Workers entry, `src/node.ts` the Node entry.
- `migrations/` D1 SQL migrations (`npx wrangler d1 migrations create running-plan <name>`).

## Commands (run from repo root)

- `bash scripts/verify.sh api` lint boundaries, typecheck, tests. This is what CI and the Stop hook run.
- `npm run dev -w api` local Workers dev server with a local D1.
- `npm run dev:node -w api` the same app on Node with in-memory storage (portability check).

## Notes

- The Mac runs Node 26 with npm 12; CI runs Node 22. Change dependencies with npm 12: npm 11 crashes with
  `Cannot read properties of null (reading 'edgesOut')` when it adds or changes vitest 4.x.
- npm 12 blocks dependency install scripts. esbuild, workerd and fsevents are blocked and work without them
  (their binaries come from platform packages). Do not approve install scripts (`npm install-scripts approve`)
  without asking the human.
- Adapter tests under `api/test/adapters/cloudflare/` run in workerd with a local D1 through `@cloudflare/vitest-plugin` (the
  renamed `@cloudflare/vitest-pool-workers`, which is deprecated and ships a workerd too old for our
  `compatibility_date`). `vitest.config.ts` has two projects: `node` (everything else) and `d1`. Migrations in
  `migrations/` are applied to the test database automatically.
- D1 is SQLite: keep SQL to portable basics (no SQLite-only JSON tricks) so a later move to Postgres stays a
  dialect change, not a redesign. Use integer seconds for durations and `TEXT` `YYYY-MM-DD` for local dates.
- Auth (task 2.4): email one-time code, HS256 access tokens (15 min), rotating refresh tokens (60 days, reuse of a
  rotated token revokes its family), scopes by client type. Codes and refresh tokens are stored only as HMAC
  hashes. The Workers entry needs the secrets `JWT_SECRET` (32+ characters; the entry refuses to run without it),
  the `EMAIL` send binding and `MAIL_FROM`; without them it refuses to run unless `ALLOW_LOG_EMAIL=1` (local dev only: codes
  are printed). Put local values in `api/.dev.vars` (gitignored). Only `cf-connecting-ip` is trusted for rate limits.
  Access tokens stay valid until they expire (15 minutes) after their refresh family is revoked; account delete
  takes effect at once because each request checks the user still exists. Production secrets are set by the human with `npx wrangler secret put <NAME>`.
- Pace derivation (`src/domain/paces.ts`) uses the Riegel race-equivalence model, exponent 1.06 (design §12.2 decided
  for backlog 2.9). Its zone anchors (easy 1.20 to 1.35 of 5K pace, long 1.15 to 1.30, tempo 10K pace ±3%, interval 3K
  to 5K pace) and the heart-rate bands are starting values awaiting the coach review (backlog H.1).
- Rule engine (`src/domain/engine.ts`, task 2.1): `generatePlan({ answers, today })` returns a draft with the
  assumptions it made and warnings (its own notices plus the validators' findings; session ids are not in a draft, so
  validator warnings carry only the week). 5K preset only until 2.2. Week 1 is 85% of the baseline (70% when pain is
  flagged), growth 7 to 8% a week, a down week (x0.88, then back to the earlier level) every 4th week (3rd when
  cautious), a two-week taper. No run passes its limit (long 14 km, quality 12 km, easy 10 km), which also bounds the
  weekly volume. The plan always ends on the goal date; the second hard session of a 5-run week is dropped to an easy
  run when no day has an easy or rest day on each side. Fewer than 3 free days is an error (the route returns 400).
  Every number is a starting value for the coach review (H.1); bump `ENGINE_VERSION` when one changes.
  A goal date that is too soon keeps 8 weeks and suggests a later date; one that is too far starts the plan later;
  the proper edge cases are task 2.10. Add property tests (fast-check) for each new invariant.
- Progress and the weekly review (`src/domain/insights.ts`, tasks 2.15 and 2.18): `computeProgress` and
  `computeWeeklyReview` are pure. A session is done when marked done or its match is confirmed; "missed" only after
  its day is over (so due can exceed done + skipped + missed by what is left today); actual volume comes from the
  confirmed activity, or the plan when a session was marked done by hand; strength and cross-training count toward
  time only. On track means 70% or more of the judged sessions done (at least 3 judged). A review looks back at a finished
  week: its review day is the first chosen weekday on or after the week's last day (the last day itself by default),
  and it is due for seven days from then; after an import it is also due once the week has something done. Thresholds are for the coach review (H.1).
- Plans and sessions (task 2.5): every query is scoped to the signed-in user, so another user's id is a 404. Writes
  compare the base revision (`If-Match`) atomically; a session write also moves the plan's `contentRevision` in the
  same D1 batch (a transaction), with later statements guarded by SQLite's `changes()` so a lost race writes
  nothing. Deletes are tombstones. Creates are idempotent: the request's canonical hash is stored, so a repeat is a
  200 and the same id with another body a 409. The D1 SQL in `adapters/cloudflare/` may use SQLite features; only
  the migrations stay portable.
- Test routes with `app.request(...)` against `createApp(memoryDeps())`; no network in unit tests.
- Rule engine tests are table-driven; add property tests (fast-check) for invariants such as bounded weekly load growth.
