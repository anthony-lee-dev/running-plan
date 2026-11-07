import { Hono } from "hono";
import type { Deps } from "./ports";
import type { generatePlan } from "./domain/engine";
import { accountRoutes } from "./http/account";
import { activityRoutes } from "./http/activities";
import { authRoutes } from "./http/auth";
import { matchRoutes } from "./http/matches";
import { generateRoutes } from "./http/generate";
import { healthRoutes } from "./http/health";
import { planRoutes } from "./http/plans";
import { problem } from "./http/problem";
import { profileRoutes } from "./http/profile";
import { progressRoutes } from "./http/progress";
import { syncRoutes } from "./http/sync";

/** Builds the HTTP app from its dependencies. Runtime-agnostic: no Cloudflare or Node APIs here. */
export function createApp(deps: Deps, options: { generate?: typeof generatePlan } = {}) {
  const app = new Hono();
  app.route("/", healthRoutes(deps));
  app.route("/", authRoutes(deps));
  app.route("/", accountRoutes(deps));
  app.route("/", profileRoutes(deps));
  // Each route checks its own token, so the order here does not decide who may call what.
  app.route("/", generateRoutes(deps, options.generate));
  app.route("/", matchRoutes(deps));
  app.route("/", planRoutes(deps));
  app.route("/", progressRoutes(deps));
  app.route("/", syncRoutes(deps));
  app.route("/", activityRoutes(deps));
  app.notFound((c) => c.json({ error: "not_found" }, 404));
  app.onError((error, c) => {
    // Name and message only: adapters keep addresses and codes out of their error messages.
    console.error(`unhandled error: ${error.name}: ${error.message}`);
    return problem(c, 500, "internal_error", "Something went wrong");
  });
  return app;
}
