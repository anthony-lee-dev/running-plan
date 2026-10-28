import { Hono } from "hono";
import type { Deps } from "../ports";

export function healthRoutes(deps: Deps) {
  const routes = new Hono();
  routes.get("/v1/health", async (c) => {
    const storage = await deps.health.check();
    return c.json(
      { status: storage ? "ok" : "degraded", storage, time: deps.clock.now().toISOString() },
      storage ? 200 : 503,
    );
  });
  return routes;
}
