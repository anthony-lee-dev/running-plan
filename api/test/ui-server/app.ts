// The API the iOS UI tests run against: the real app with in-memory stores, plus `/__test/*` routes that let a
// test read the last sign-in code and check the app really called this server. Lives under `test/` so it never
// ships: the Workers entry is `src/index.ts` and has none of this.
import { Hono } from "hono";
import { createApp } from "../../src/app";
import { MemoryEmailSender, memoryDeps } from "../../src/adapters/memory";

export interface UiTestServer {
  app: Hono;
  /** Requests the app answered successfully (status below 400), by `METHOD /path`. */
  counts: Map<string, number>;
}

export function buildUiTestServer(): UiTestServer {
  const email = new MemoryEmailSender();
  const api = createApp(memoryDeps({ email }));
  const counts = new Map<string, number>();
  const app = new Hono();

  app.get("/__test/stats", (c) => c.json({ requests: Object.fromEntries(counts) }));
  app.get("/__test/codes/latest", (c) => {
    const to = c.req.query("email");
    const code = email.sent.filter((s) => s.to === to).at(-1)?.code;
    return code ? c.json({ code }) : c.json({ error: "no_code" }, 404);
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
