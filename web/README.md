# web

Phase 2 planning companion: sign in, see the plan, adjust sessions (mark done or skipped, move to another day).
It will not upload running-session data. React + Vite, TypeScript, Vitest with Testing Library.

- `npm run dev -w web` serves the app with `/v1` proxied to the API on `localhost:8787` (`npm run dev -w api`;
  with `ALLOW_LOG_EMAIL=1` in `api/.dev.vars` the sign-in code is printed in the API's terminal).
- `bash scripts/verify.sh web` typechecks, tests, builds, and fails if `src/api/schema.d.ts` is out of date.
  After a spec change run `npm run generate:types -w web` and commit the result.
- `src/api/client.ts` is the only code that talks to the API: bearer token, one shared refresh on a 401, and the
  base revision in `If-Match` on every edit. A conflict (409) is shown to the user and the plan reloaded, never merged.
- Tokens live in `sessionStorage` (they end with the tab). The access token is never put in a URL.
- Runs tab (issue #131): the newest 100 imported runs (`GET /v1/activities`, readable with a web token) and a summary of one:
  distance, time, pace, heart rate and climb, each left out when the source did not record it. Splits, heart-rate zones and
  routes exist only on the phone (nothing more is uploaded), so the page says so.
- Run summary (issue #132): Run details of a running activity that is not ignored shows `RunSummaryCard`. It reads
  `GET .../summary?today=` (the local day), shows that at once (stored AI text, or the template), calls `POST .../summary:generate` once when
  the server says `canGenerate`, and swaps the reply in with a "Generated summary" label. A 429 or any failure keeps what is shown; no
  refresh button. `nextStep` (the next planned session, or the fixed pain guidance as a notice) is written by the server. The card's
  link turns AI run summaries off or on (`aiSummaries` on the profile, shared with the iPhone app).
- Progress tab (issue #137): "Your running" shows distance, time, run count and average pace for this week or month, a bar per
  period (8 weeks, 6 months) and how it compares with the period before. `runTotals.ts` works it out from the run summaries
  (`listActivitiesSince`, which follows the cursor from the earliest day shown, so the totals are not cut at 100 runs) with the
  same rules as the iPhone: calendar weeks Monday to Sunday on `localDate`, ignored runs and other workout types left out, pace
  from the runs that have a distance, today from the local clock (`localToday`, never the UTC date). For a week it adds the plan
  week from `GET /v1/plans/{id}/progress`, labelled apart because plan weeks start on the plan's own start date and the server
  counts only matched runs. No plan, or a failed plan read, leaves the totals alone.
- `public/_headers` sets a strict Content-Security-Policy (`connect-src 'self'`: the API must be on the same origin)
  and the other security headers; the refresh token is in `sessionStorage`, so the CSP is a second layer behind
  React's escaping of all server text.
- Hosting: the API Worker serves the built app itself (`[assets]` in `api/wrangler.toml`: `/v1/*` runs the Worker, every other
  path is a static file from `web/dist` with the SPA fallback to `index.html`). The page and `/v1` share one origin, so there
  is no CORS and `_headers` keeps `connect-src 'self'`. Asset responses get the headers in `public/_headers`; API responses
  are unchanged, so the iOS app sees the same API. A separate web Worker would need a service binding for no gain.

## Deploy the web app

A human step (agents do not run `wrangler deploy`). It reuses the existing Worker `running-plan-api`, so its D1 database and
secrets (`JWT_SECRET`, `MAIL_FROM`) and the `EMAIL` binding stay as they are: sign-in codes are emailed, as for the iPhone app.
From the repo root, after `npm ci`:

```bash
npm run build -w web
```

```bash
cd api && npx wrangler deploy
```

```bash
cd .. && npm run smoke -w api
```

Then open <https://running-plan-api.anthonyhklee.workers.dev/>, type your email, and enter the code that arrives by email.
Your plan and runs load from the same account as the iPhone app. `wrangler deploy` fails if `web/dist` does not exist, so build
first; rebuild and redeploy whenever the web app changes. No D1 migration is needed. To try it locally first:
`npm run build -w web`, put `JWT_SECRET` (32+ characters) and `ALLOW_LOG_EMAIL=1` in `api/.dev.vars`, run
`npx wrangler d1 migrations apply running-plan --local` and `npm run dev -w api`, and open `http://localhost:8787/`
(the code is printed in the terminal).
