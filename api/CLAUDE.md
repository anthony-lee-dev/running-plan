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

- npm 11 (including the newest 11.x) crashes with `Cannot read properties of null (reading 'edgesOut')` when it
  adds or changes vitest 4.x. Change dependencies with `npx -y npm@12 install ...` instead; `npm ci` and
  `npm install` with no arguments work fine from the committed lockfile. npm 12 wants Node 24.15 or later.
- Stay on vitest 4.x: `@cloudflare/vitest-pool-workers` (task 1.5) supports `^4.1`, not 5.

- D1 is SQLite: keep SQL to portable basics (no SQLite-only JSON tricks) so a later move to Postgres stays a
  dialect change, not a redesign. Use integer seconds for durations and `TEXT` `YYYY-MM-DD` for local dates.
- Test routes with `app.request(...)` against `createApp(memoryDeps())`; no network in unit tests.
- Rule engine tests are table-driven; add property tests (fast-check) for invariants such as bounded weekly load growth.
