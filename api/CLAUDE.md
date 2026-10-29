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
  route (2.3) must reject an unknown `presetId` with a 400: the engine throws a plain Error for one. Week 1 is 85% of the baseline (70% when pain is
  flagged), growth 7 to 8% a week, a down week (x0.88, then back to the earlier level) every 4th week (3rd when
  cautious), a two-week taper. No run passes its limit (long 14 km, quality 12 km, easy 10 km), which also bounds the
  weekly volume. The plan always ends on the goal date; the second hard session of a 5-run week is dropped to an easy
  run when no day has an easy or rest day on each side. Fewer than 3 free days is an error (the route returns 400).
  Every number is a starting value for the coach review (H.1); bump `ENGINE_VERSION` when one changes.
  Goal dates (design 6.5): too soon keeps 8 weeks and suggests a later date; 13 to 16 weeks away adds extra base weeks
  that hold the conservative start; further away starts the plan later with 16 weeks; a past date is dropped. A weekly
  distance under 4 km gets a `baseline_far_below_goal` notice with a later date and a run-walk suggestion. Add property tests (fast-check) for each new invariant.
- Test routes with `app.request(...)` against `createApp(memoryDeps())`; no network in unit tests.
- Rule engine tests are table-driven; add property tests (fast-check) for invariants such as bounded weekly load growth.
