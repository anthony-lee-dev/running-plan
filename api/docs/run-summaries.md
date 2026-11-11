# Run summaries and the model

Part of the API guide (`api/CLAUDE.md` has the index). Read this before changing `src/domain/run-facts.ts`, `run-summary-*.ts`, `summary-check.ts`, `src/http/summaries.ts`.

- Run summaries (issue #132, `src/http/summaries.ts`): `GET /v1/activities/{id}/summary?today=` never calls a model and never
  writes. `loadSummaryContext` reads the run, the user's runs of the 28 days before it, its confirmed match, the matched session's
  after-run check-ins and the plan's sessions (about a dozen D1 round trips with the token check, well under 50), and `domain/run-facts.ts` turns them into
  ready-formatted facts: every number a summary may contain. Never put free text (check-in notes, titles, source apps), ids or
  absolute dates in the facts: they are what a model would see. `domain/run-summary-text.ts` is the template (also the oracle for
  the model's text), `domain/summary-check.ts` the number, wording and shape checks (stricter when pain is flagged). The facts are
  hashed (`canonicalHash`) and a stored paragraph (`activity_summaries`, migration 0006) is served only while its hash and
  `PROMPT_VERSION` still match; bump `PROMPT_VERSION` with any change to the prompt or the facts' meaning. `nextStep` is written by
  the server on every read from the plan relative to `today` and is never stored or sent to a model; with a pain flag on any
  after-run check-in it is `PAIN_GUIDANCE`, word for word (the iOS check-in screen shows the same sentence: change both together).
  For a run with no matched session the "next" session comes from the plan that covers `today`. The hash covers the run's own facts and which way the comparison goes, not its aggregates, so importing another similar run does not write the paragraph again. Intervals/tempo runs are not compared with other runs; fewer than 3 similar runs (distance within 20%, 28 days) say so.
  Derived data: summaries stay out of the account export and sync (the cascade deletes them with the account). The profile's
  `aiSummaries` (on by default, migration 0006) turns the AI off per account: the GET then answers the template with reason `disabled`.
- Run summaries, the model (issue #132, `POST .../summary:generate`): the Workers AI binding (`[ai]` in wrangler.toml, `env.AI`) is
  touched only by `adapters/cloudflare/workers-ai-narrator.ts` behind the `RunNarrator` port (default model
  `@cf/meta/llama-3.1-8b-instruct-fp8-fast`, 300 output tokens, 8 s timeout, JSON-schema output); a Claude adapter is a one-file
  swap. The domain builds the prompt (`run-summary-prompt.ts`: facts only, strict extra rule for pain) and reads the answer
  (`{"paragraph": "..."}`); every answer goes through `checkParagraph`, one retry, then the template. Order in the route: 404, off
  switches (account `aiSummaries`, `AI_SUMMARIES` var) -> `disabled`, stored paragraph (or remembered `check_failed`), no model wired
  -> `ai_unavailable`, per-account limits (30 an hour, 60 a day; 429 + `Retry-After`; counted only once the request would reach the model, and a denied one burns only its own account's counters, never the global cap),
  then each model call counts once against the global day cap (`AI_DAILY_CAP`, default 600, a fixed UTC-day window like the Workers AI
  allowance; over it `over_limit`). A quota error from the model gives `over_limit` and sets a 15-minute marker (`RateLimiter.peek`) so nothing calls the exhausted model again; timeouts and failures give `ai_unavailable`
  and store nothing; two failed checks store a template row so reopening does not spend more. Logs carry reason codes only: never the
  facts, the prompt or the model's text. Workers Free: the allowance is 10,000 neurons a day (about 10 a call), a daily cap of 600
  leaves headroom; on Workers Paid overage is billed, so raise the cap deliberately. `AI_SUMMARIES` is a plain var that ships `"on"` in wrangler.toml by the human's decision on 2026-11-11 after the device check (#82, the legal wording, is still open); setting `"off"` and deploying is still the
  kill switch (a deploy resets a dashboard edit, so the value in wrangler.toml is what counts). Two concurrent generates for one run both call the model and both count; the later `put` wins, and the hash check on read keeps the text correct. Tests use `FakeNarrator`; the adapter test uses a stub binding. `wrangler dev` calls Workers AI
  remotely and spends neurons. `npm run eval-summary -w api` (manual, needs the human's account id and token, never in CI) runs 30
  fixtures through candidate models and prints the share of AI text that passes the checks and the neurons spent.
- Eval lessons (issue #160; the first real eval gave 0/30 on every model):
  - Models write units in words ("59 minutes", "5:51 per kilometre", "1 hour 17 minutes", "152 beats per minute"). `canonicalUnits`
    in `summary-check.ts` rewrites only the unit to the facts' own form before the number check; values are never touched, so a
    wrong number still fails. "28 days" is accepted like "4 weeks". Spelled-out numbers ("four") still fail, the prompt says digits.
    A letter stuck to a digit ("took44") is a `shape` failure. Run-together words with no digit ("wascompleted") are not caught by
    any check: only the prompt (v2) discourages them.
  - Workers AI answers differ by model: `response` as a JSON string or an object, or chat-completion `choices[0].message.content`
    (Granite gave `malformed: undefined` until read this way). `modelAnswer` (`run-summary-prompt.ts`) reads all of them; the adapter
    and the eval both use it. Judge the whole `result`, never `result.response`.
  - The eval's fixtures and `judge` live in `scripts/eval-summary-fixtures.ts`. `OFFLINE=file.json` re-judges saved results with no
    network; `SAVE=file.json` saves them from a live run. `test/summary-eval-offline.test.ts` runs `test/fixtures/summary-eval-captured.ts`
    (one paragraph real from the issue, the rest synthetic and labelled so) through the same path in verify. After a live eval, add
    real paragraphs there. Known laxness: the check matches quantities, not which fact they belong to (the average pace written
    as this run's pace passes).
