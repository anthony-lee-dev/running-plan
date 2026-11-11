# Rule engine, presets, paces, the generate route

Part of the API guide (`api/CLAUDE.md` has the index). Read this before changing `src/domain/engine.ts`, `presets.ts`, `paces.ts`, `strength.ts`, `validators.ts`, `src/http/generate.ts`.

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
