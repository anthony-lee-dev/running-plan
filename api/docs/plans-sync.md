# Plans, sessions and sync

Part of the API guide (`api/CLAUDE.md` has the index). Read this before changing `src/http/plans.ts`, `sync.ts`, `src/domain/sync.ts`, `session-edit.ts`.

- Plans and sessions (task 2.5): every query is scoped to the signed-in user, so another user's id is a 404. Writes
  compare the base revision (`If-Match`) atomically; a session write also moves the plan's `contentRevision` in the
  same D1 batch (a transaction), with later statements guarded by SQLite's `changes()` so a lost race writes
  nothing. Deletes are tombstones. Creates are idempotent: the request's canonical hash is stored, so a repeat is a
  200 and the same id with another body a 409. The D1 SQL in `adapters/cloudflare/` may use SQLite features; only
  the migrations stay portable.
- Sync (task 2.6, `src/http/sync.ts`, `src/domain/sync.ts`, `SyncStore`): `POST /v1/sync` applies operations in
  order. A request the spec forbids (unknown field, bad kind or key, bad `plan.create` or check-in data, a bad cursor, a
  repeated key) is a 400 for the whole request; what only stored data can judge (missing entity, a date outside the
  plan, an id in use) is `rejected` on that operation; a stale `baseRevision` is `conflict` with the server's `Plan` or
  `Session` and is **not** remembered, so "keep mine" can resend under the same key. Only `applied` operations are
  stored (`sync_ops`, keyed per user, with a hash of the operation): a repeat is `duplicate` with the original revision
  and costs nothing, the same key on another edit is `rejected` (`idempotency_key_reused`). Remembering happens in one
  batch after the loop, so a crash between an edit and that write replays it: creates are idempotent by id and hash,
  an update replays as a conflict whose server copy is the user's own edit. **Query budget**: the route spends
  `QUERY_LIMIT` (50) minus `FIXED_QUERIES` (token check, remembering, the 4-query pull, a spare), charging each
  operation its worst-case `OP_COST` and each 50 keys one lookup (D1 allows 100 bound values per query); when the
  next operation does not fit it stops and `results` is shorter than `operations`. Change a store method that sync
  calls and `test/adapters/cloudflare/sync-budget.test.ts` (counts real D1 queries) says whether the costs still hold.
  The pull pages each table by `(updated_at, id)` with a position per table in the cursor (tombstones included, plan
  with weeks, no sessions; a deleted plan's sessions are not tombstoned, the client drops them with the plan);
  `hasMore` when any table hit its page. A session or match write moves the plan's `updated_at` along with its
  `content_revision`, so the pull returns the plan with the new number. Known limit: a write takes its `updated_at`
  before it commits, so a request that reads the clock, then loses the race to a pull that advances the cursor, then
  commits can leave its rows behind that cursor (the same holds for two writes in one millisecond); revision checks
  still stop lost writes, the risk is only a missed pull, fixed by the row's next change. The pull also carries proposals (a fifth
  position `q` in the cursor; a cursor without it reads proposals from the start). Before the pull the route runs `proposals.markStale`
  (one query), so a proposal whose plan moved is pulled as `stale` with a new `updatedAt`. `FIXED_QUERIES` is 9 (token, remembering,
  mark stale, the 5-query pull, a spare). A `checkin.create` with `pain: true` costs `PAIN_CHECKIN_COST` (12), because it also raises
  an urgent proposal (see Proposals); `opCost(op)` picks the cost, and `sync-budget.test.ts` measures that case too.
