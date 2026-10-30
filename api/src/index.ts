// Cloudflare Workers entry. The only place outside adapters/cloudflare that sees Cloudflare bindings.
import { createApp } from "./app";
import { CloudflareEmailSender, type SendBinding } from "./adapters/cloudflare/cloudflare-email";
import { D1ActivityStore } from "./adapters/cloudflare/d1-activity-store";
import { D1MatchStore } from "./adapters/cloudflare/d1-match-store";
import { D1AuthStore } from "./adapters/cloudflare/d1-auth-store";
import { D1HealthProbe } from "./adapters/cloudflare/d1-health";
import { D1ProfileStore } from "./adapters/cloudflare/d1-profile-store";
import { D1PlanStore } from "./adapters/cloudflare/d1-plan-store";
import { D1RateLimiter } from "./adapters/cloudflare/d1-rate-limiter";
import { LogEmailSender, systemClock, webIdSource } from "./adapters/memory";

export interface Env {
  DB: D1Database;
  /** Signs access tokens and keys the hashes of codes and refresh tokens: `wrangler secret put JWT_SECRET`. */
  JWT_SECRET?: string;
  /** Cloudflare Email Sending binding (`[[send_email]]` in wrangler.toml) and the sender address on an onboarded
   * domain. Both are required unless ALLOW_LOG_EMAIL is set. */
  EMAIL?: SendBinding;
  MAIL_FROM?: string;
  /** Local dev only (`api/.dev.vars`): print sign-in codes instead of emailing them. Never set in production. */
  ALLOW_LOG_EMAIL?: string;
}

const misconfigured = () =>
  new Response(JSON.stringify({ type: "misconfigured", title: "Server is not configured", status: 500 }), {
    status: 500,
    headers: { "content-type": "application/problem+json" },
  });

export default {
  fetch(request: Request, env: Env, ctx: ExecutionContext) {
    // Fail closed: never run with a missing or short signing secret, and never log codes unless asked to.
    if (!env.JWT_SECRET || env.JWT_SECRET.length < 32) return misconfigured();
    const mailConfigured = Boolean(env.EMAIL && env.MAIL_FROM);
    if (!mailConfigured && env.ALLOW_LOG_EMAIL !== "1") return misconfigured();
    const app = createApp({
      clock: systemClock,
      health: new D1HealthProbe(env.DB),
      auth: new D1AuthStore(env.DB),
      profiles: new D1ProfileStore(env.DB),
      plans: new D1PlanStore(env.DB),
      activities: new D1ActivityStore(env.DB),
      matches: new D1MatchStore(env.DB),
      rateLimiter: new D1RateLimiter(env.DB),
      email:
        env.EMAIL && env.MAIL_FROM
          ? new CloudflareEmailSender({ binding: env.EMAIL, from: env.MAIL_FROM })
          : new LogEmailSender(),
      ids: webIdSource,
      authConfig: { jwtSecret: env.JWT_SECRET },
    });
    return app.fetch(request, env, ctx);
  },
} satisfies ExportedHandler<Env>;
