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
- Test routes with `app.request(...)` against `createApp(memoryDeps())`; no network in unit tests.
- Rule engine tests are table-driven; add property tests (fast-check) for invariants such as bounded weekly load growth.
