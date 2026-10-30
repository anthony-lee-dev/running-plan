import { Hono } from "hono";
import type { Deps } from "./ports";
import type { generatePlan } from "./domain/engine";
import { activityRoutes } from "./http/activities";
import { authRoutes } from "./http/auth";
import { matchRoutes } from "./http/matches";
import { generateRoutes } from "./http/generate";
import { healthRoutes } from "./http/health";
import { planRoutes } from "./http/plans";
import { problem } from "./http/problem";
import { profileRoutes } from "./http/profile";

/** Builds the HTTP app from its dependencies. Runtime-agnostic: no Cloudflare or Node APIs here. */
export function createApp(deps: Deps, options: { generate?: typeof generatePlan } = {}) {
  const app = new Hono();
  app.route("/", healthRoutes(deps));
  app.route("/", authRoutes(deps));
  app.route("/", profileRoutes(deps));
  // Before the plan routes: generate is public, and they guard /v1/plans/* with a token.
  app.route("/", generateRoutes(deps, options.generate));
  // Before the plan routes too, so their token check on /v1/sessions/* does not run twice.
  app.route("/", matchRoutes(deps));
  app.route("/", planRoutes(deps));
  app.route("/", activityRoutes(deps));
  app.notFound((c) => c.json({ error: "not_found" }, 404));
  app.onError((error, c) => {
    // Name and message only: adapters keep addresses and codes out of their error messages.
    console.error(`unhandled error: ${error.name}: ${error.message}`);
    return problem(c, 500, "internal_error", "Something went wrong");
  });
  return app;
}
