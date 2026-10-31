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
  validator warnings carry only the week). Presets live in `src/domain/presets.ts` (5K 8 to 12 weeks, 10K 8 to 14, half
  marathon 10 to 16, each with its own tier caps, run limits and quality sessions); strength sessions come from the
  curated library in `src/domain/strength.ts` (one or two short sessions a week, never on or before a hard day, always
  leaving a rest day). `test/engine-variants.test.ts` snapshots the 54 base variants of design 6.2 plus boundary cases:
  review its diff when a plan changes, update it with `npx vitest -u`, and bump `ENGINE_VERSION`. The generate
  route rejects an unknown `presetId` with a 400 before the engine runs (the engine throws a plain Error for one). Week 1 is 85% of the baseline (70% when pain is
  flagged), growth 7 to 8% a week, a down week (x0.88, then back to the earlier level) every 4th week (3rd when
  cautious), a two-week taper. No run passes its limit (long 14 km, quality 12 km, easy 10 km), which also bounds the
  weekly volume. The plan always ends on the goal date; the second hard session of a 5-run week is dropped to an easy
  run when no day has an easy or rest day on each side. Fewer than 3 free days is a `RangeError` (the route returns 422 `no_plan_fits`; the schema's four unavailable days keep it out of reach today).
  Every number is a starting value for the coach review (H.1); bump `ENGINE_VERSION` when one changes.
  Goal dates (design 6.5): too soon keeps 8 weeks and suggests a later date; 13 to 16 weeks away adds extra base weeks
  that hold the conservative start; further away starts the plan later with 16 weeks; a past date is dropped. A weekly
  distance under 4 km gets a `baseline_far_below_goal` notice with a later date and a run-walk suggestion. Add property tests (fast-check) for each new invariant.
- Generate route (task 2.3, `src/http/generate.ts`): public, mounted before the plan routes that require a token.
  Rate limits (per IP 300 an hour, per `X-Device-Id` 120 an hour) are counted before the body is read; the body is
  capped at 16 KB and the response at 256 KB; `src/domain/generate-input.ts` validates strictly. Never log the
  answers: an engine error is replaced by a generic one before `onError` sees it.
- Activities (task 2.11, `src/domain/activities.ts`): an upload dedupes on `source` + `externalId` (unchanged is
  `duplicate`, changed is `updated`) and, for Garmin re-writes with a new id, on the same type with the start within
  2 minutes and duration and distance within 3% (60 s, 100 m floors). Such a re-write keeps the stored id and values
  and only fills gaps, so two copies of one run in Health settle; the disposition always stays. The D1 store does one
  read (a day either side of the batch, plus the batch's source ids at any date) and one `db.batch` write, which fails
  whole on a clashing insert rather than dropping it. Keep
  every request to a few queries: Workers Free allows 50 D1 queries per request, and a batch counts as one.
- Matches (task 2.12, `src/domain/matches.ts`): one match per session and per activity; matching an activity
  elsewhere moves it. Confirming sets the session `done` (new revision, plan `contentRevision` + 1) and the activity
  `matched`; unlinking, downgrading to a suggestion or a new disposition undoes only what the match did. The route
  loads the state, the pure `planMatchChange` decides, and `MatchStore.apply` writes it in one D1 batch whose first
  statement aborts it (`json('{')`) if anything read has changed; the route retries up to three times.
  Deleting a session or a plan unlinks its matches (task 2.21): the match rows go and an activity they had matched
  returns to the inbox with a new revision. The D1 store does it in the delete's batch, guarded by the tombstone time
  just written, so a refused delete unlinks nothing; the memory plan store calls the match store through
  `onSessionsDeleted`. Reads still skip matches of deleted sessions, for rows written before this.
- Suggested sessions (task 2.12, `src/domain/suggestions.ts`): the upload results carry `suggestedSessionId` for
  every activity of the batch still in the inbox (a re-send gets it again). It is only returned, never written as a
  match row; the client confirms with `PUT /match`. Candidates come from `MatchStore.suggestionCandidates` (one query:
  live `planned` sessions on the batch's dates with no match). Rules: same local date, run workouts to easy/long/
  intervals/tempo, strength to strength, other types to custom, never rest; planned time (`plannedTimeSec`) within a
  factor of 2 of the duration (a session with no planned time is allowed but ranks last); closest fit first, and a
  session is suggested to at most one activity per batch. Starting values for the coach review (H.1).
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
- Proposal engine (`src/domain/proposals.ts`, task 2.13): `proposeAdjustments({ plan, checkIns, matches, today })`
  returns proposal drafts and never edits the plan. Rules: a missed key session (last 14 days, not done, no confirmed
  match) is dropped, one proposal each and urgent; pain in the last 7 days makes next week 30% lighter with hard
  sessions turned easy (urgent, and the only load proposal); two of the last three after-session check-ins "much
  harder" (effort 8+ or feel 1) ease next week by 15%; three easy ones in a row add 5% to next week's easy and long
  runs. User-owned sessions are included but flagged `userOwned` (locked unless the user opts in); blank plans are
  off unless `adaptive`. Each draft has a stable `key` so a dismissed proposal is not made again; the API task
  (2.14) adds ids, the plan revision and the status. Numbers are starting values for the coach review (H.1).
- Contract tests (task 2.7): `test/support/api-contract.ts` runs the same cases against the Node app
  (`test/api-contract.test.ts`) and the Workers entry with a local D1 (`test/adapters/cloudflare/api-contract.test.ts`).
  Each response must match `spec/openapi.yaml` (documented status, documented headers such as `ETag`, content type, body schema); request bodies are checked
  against the spec too, and a body the spec forbids (an unknown field, also inside an `allOf`) must get a 400. The
  checker (`test/support/openapi.ts`) uses `@cfworker/json-schema` because workerd blocks Ajv's `new Function`. A new
  endpoint adds its cases there and leaves `NOT_BUILT`; the last test fails for a built operation with no case.
- UI-test server (task 3.9, `test/ui-server/`): the app with in-memory stores plus `/__test/stats` (successful requests)
  and `/__test/codes/latest?email=` (the last sign-in code), on `127.0.0.1` only (port 8790, or `UI_TEST_PORT`; 0 picks a free one). `npm run ui-test-server -w api`;
  `scripts/verify.sh ios` starts it on a free port for the iOS UI tests. It stays under `test/` so nothing of it reaches the Workers entry.
- Smoke test (task 2.22, `test/support/smoke.ts`): `npm run smoke -w api` checks the deployed Worker (or `SMOKE_URL`):
  health with storage, a generate whose engine version matches `ENGINE_VERSION`, a spec-shaped 401 (not 404) from every
  built operation that needs a token, and a 404 for an unknown path under each signed-in prefix (that is what makes the
  401s mean "deployed", so routes check their token themselves rather than guarding a whole prefix). No account, and
  nothing stored but the rate limiter's counters, so it is safe against production; run it after every deploy, from an
  up-to-date `main` (it compares the deploy with the checkout). The `smoke` vitest project exists only with `SMOKE=1`,
  so verify never needs the network; `test/smoke-local.test.ts` runs the same checks in-process. The default URL
  repeats `APIConfiguration.deployedURL` in the iOS app; change both together.
- Test routes with `app.request(...)` against `createApp(memoryDeps())`; no network in unit tests.
- Rule engine tests are table-driven; add property tests (fast-check) for invariants such as bounded weekly load growth.
