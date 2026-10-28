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

- D1 is SQLite: keep SQL to portable basics (no SQLite-only JSON tricks) so a later move to Postgres stays a
  dialect change, not a redesign. Use integer seconds for durations and `TEXT` `YYYY-MM-DD` for local dates.
- Test routes with `app.request(...)` against `createApp(memoryDeps())`; no network in unit tests.
- Rule engine tests are table-driven; add property tests (fast-check) for invariants such as bounded weekly load growth.
