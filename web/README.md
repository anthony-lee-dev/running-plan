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
- Progress is not built yet: it needs `GET /v1/plans/{id}/progress` (backlog 2.15). The Progress tab says so.
- `public/_headers` sets a strict Content-Security-Policy (`connect-src 'self'`: the API must be on the same origin)
  and the other security headers; the refresh token is in `sessionStorage`, so the CSP is a second layer behind
  React's escaping of all server text.
- Hosting is Cloudflare Workers static assets (`wrangler.jsonc`). The API has no CORS headers, so deploy both on one
  domain (`/v1/*` routed to the API worker, everything else to these assets), or set `VITE_API_URL` only after adding CORS and the API origin to `connect-src`.
