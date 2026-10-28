import { Hono } from "hono";
import type { Deps } from "./ports";
import { healthRoutes } from "./http/health";

/** Builds the HTTP app from its dependencies. Runtime-agnostic: no Cloudflare or Node APIs here. */
export function createApp(deps: Deps) {
  const app = new Hono();
  app.route("/", healthRoutes(deps));
  app.notFound((c) => c.json({ error: "not_found" }, 404));
  return app;
}
