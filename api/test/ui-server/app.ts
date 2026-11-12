// The API the iOS UI tests run against: the real app with in-memory stores, plus `/__test/*` routes that let a
// test read the last sign-in code and check the app really called this server. Lives under `test/` so it never
// ships: the Workers entry is `src/index.ts` and has none of this.
import { Hono } from "hono";
import { createApp } from "../../src/app";
import { MemoryEmailSender, memoryDeps } from "../../src/adapters/memory";
import type { RunNarrator } from "../../src/ports";

export interface UiTestServer {
  app: Hono;
  /** Requests the app answered successfully (status below 400), by `METHOD /path`. */
  counts: Map<string, number>;
}

export interface UiTestServerOptions {
  /** Called once per request, when it has been answered: `<ISO time> <METHOD> <path> <status> <ms>ms`. */
  log?: (line: string) => void;
}

export function buildUiTestServer(options: UiTestServerOptions = {}): UiTestServer {
  const email = new MemoryEmailSender();
  // Every UI test comes from one address, so the per-IP sign-in limit (15 an hour) would stop the run after a dozen
  // tests; the limits themselves are covered by the API's own tests.
  const rateLimiter = { hit: async () => ({ allowed: true, retryAfterSec: 1 }), peek: async () => 0 };
  // Stands in for the model: rewords the facts it is given, so the app can show the template first and the AI text after.
  const narrator: RunNarrator = {
    model: "ui-test",
    narrate: async ({ user }) => {
      const facts = JSON.parse(user) as { distance?: string; duration: string; average_pace?: string };
      return JSON.stringify({ paragraph: `Today you ran ${facts.distance ? `${facts.distance} in ` : ""}${facts.duration}${facts.average_pace ? ` at ${facts.average_pace}` : ""}.` });
    },
  };
  const api = createApp(memoryDeps({ email, rateLimiter, narrator }));
  const counts = new Map<string, number>();
  const app = new Hono();

  // One line per request, answered or failed, so a UI test that waited on the server can be told from one that did not.
  // CI keeps this log (verify.sh) when a shard fails.
  if (options.log) {
    const log = options.log;
    app.use("*", async (c, next) => {
      const started = Date.now();
      await next();
      log(`${new Date(started).toISOString()} ${c.req.method} ${new URL(c.req.url).pathname} ${c.res.status} ${Date.now() - started}ms`);
    });
  }

  app.get("/__test/stats", (c) => c.json({ requests: Object.fromEntries(counts) }));
  app.get("/__test/codes/latest", (c) => {
    const to = c.req.query("email");
    const code = email.sent.filter((s) => s.to === to).at(-1)?.code;
    return code ? c.json({ code }) : c.json({ error: "no_code" }, 404);
  });
  // Signs an account in and saves a 10K plan for it, the way the app's interview, preview and sign-in would, and hands
  // back the tokens. A UI test that is not about those flows launches the app signed in with them.
  app.post("/__test/seed", async (c) => {
    const body = (await c.req.json().catch(() => null)) as { email?: unknown; today?: unknown } | null;
    if (typeof body?.email !== "string" || typeof body.today !== "string") return c.json({ error: "email and today are required" }, 400);
    const post = (path: string, payload: unknown, token?: string) =>
      api.fetch(
        new Request(new URL(path, c.req.url), {
          method: "POST",
          headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
          body: JSON.stringify(payload),
        }),
      );
    await post("/v1/auth/email/start", { email: body.email });
    const code = email.sent.filter((s) => s.to === body.email).at(-1)?.code;
    const verified = await post("/v1/auth/email/verify", { email: body.email, code, clientType: "ios" });
    if (verified.status !== 200) return c.json({ error: "sign-in failed" }, 500);
    const tokens = (await verified.json()) as { accessToken: string; refreshToken: string; userId: string };
    const generated = await post("/v1/plans/generate", { answers: { goal: { distance: "10k" } }, today: body.today });
    if (generated.status !== 200) return c.json({ error: "generate failed" }, 500);
    const draft = (await generated.json()) as { sessions: object[]; assumptions?: unknown; warnings?: unknown };
    const { assumptions: _a, warnings: _w, ...fields } = draft;
    const planId = crypto.randomUUID();
    const sessions = draft.sessions.map((s) => ({ ...s, id: crypto.randomUUID() }));
    const created = await post("/v1/plans", { ...fields, id: planId, sessions }, tokens.accessToken);
    if (created.status !== 201) return c.json({ error: "save failed" }, 500);
    return c.json({ accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, userId: tokens.userId, planId });
  });
  app.all("*", async (c) => {
    const res = await api.fetch(c.req.raw);
    if (res.status < 400) {
      const key = `${c.req.method} ${new URL(c.req.url).pathname}`;
      counts.set(key, (counts.get(key) ?? 0) + 1);
    }
    return res;
  });
  return { app, counts };
}
