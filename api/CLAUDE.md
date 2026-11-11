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

## Feature notes (read only the ones you need)

Decisions and traps for each area live in `api/docs/`, one file per area, so a task reads only what it touches.
Before you change a file, read its note. When a task teaches something worth keeping, add it to that area's note.
This file is only for what every API task needs.

| You are changing | Read |
|---|---|
| `src/domain/auth.ts`, `jwt.ts`, `src/http/auth.ts`, `account.ts` | `api/docs/auth-account.md` |
| `src/domain/engine.ts`, `presets.ts`, `paces.ts`, `strength.ts`, `validators.ts`, `src/http/generate.ts` | `api/docs/plan-engine.md` |
| `src/http/plans.ts`, `sync.ts`, `src/domain/sync.ts`, `session-edit.ts` | `api/docs/plans-sync.md` |
| `src/domain/activities.ts`, `matches.ts`, `suggestions.ts` and their routes | `api/docs/activities-matches.md` |
| `src/domain/insights.ts`, `src/http/progress.ts`, `reviews.ts` | `api/docs/progress-review.md` |
| `src/domain/proposals.ts`, `proposal-model.ts`, `src/http/proposals.ts` | `api/docs/proposals.md` |
| `src/domain/run-facts.ts`, `run-summary-*.ts`, `summary-check.ts`, `src/http/summaries.ts` | `api/docs/run-summaries.md` |

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
- Test routes with `app.request(...)` against `createApp(memoryDeps())`; no network in unit tests.
- Rule engine tests are table-driven; add property tests (fast-check) for invariants such as bounded weekly load growth.
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
- The Worker also serves the built web app from `../web/dist` (`[assets]` in `wrangler.toml`, `run_worker_first = ["/v1/*"]`),
  so deploys need `npm run build -w web` first. Only `/v1/*` reaches `src/index.ts`; do not widen that or the web CSP breaks.
