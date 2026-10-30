import { Hono } from "hono";
import type { Deps } from "./ports";
import { authRoutes } from "./http/auth";
import { healthRoutes } from "./http/health";
import { problem } from "./http/problem";

/** Builds the HTTP app from its dependencies. Runtime-agnostic: no Cloudflare or Node APIs here. */
export function createApp(deps: Deps) {
  const app = new Hono();
  app.route("/", healthRoutes(deps));
  app.route("/", authRoutes(deps));
  app.notFound((c) => c.json({ error: "not_found" }, 404));
  app.onError((error, c) => {
    // Name and message only: adapters keep addresses and codes out of their error messages.
    console.error(`unhandled error: ${error.name}: ${error.message}`);
    return problem(c, 500, "internal_error", "Something went wrong");
  });
  return app;
}
