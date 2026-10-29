// Cloudflare Workers entry. The only place outside adapters/cloudflare that sees Cloudflare bindings.
import { createApp } from "./app";
import { D1AuthStore } from "./adapters/cloudflare/d1-auth-store";
import { D1HealthProbe } from "./adapters/cloudflare/d1-health";
import { D1ProfileStore } from "./adapters/cloudflare/d1-profile-store";
import { D1RateLimiter } from "./adapters/cloudflare/d1-rate-limiter";
import { LogEmailSender, systemClock, webIdSource } from "./adapters/memory";
import { ResendEmailSender } from "./adapters/resend/resend-email";

export interface Env {
  DB: D1Database;
  /** Signs access tokens and keys the hashes of codes and refresh tokens: `wrangler secret put JWT_SECRET`. */
  JWT_SECRET?: string;
  /** Resend API key and the verified sender address. Required unless ALLOW_LOG_EMAIL is set. */
  RESEND_API_KEY?: string;
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
    const mailConfigured = Boolean(env.RESEND_API_KEY && env.MAIL_FROM);
    if (!mailConfigured && env.ALLOW_LOG_EMAIL !== "1") return misconfigured();
    const app = createApp({
      clock: systemClock,
      health: new D1HealthProbe(env.DB),
      auth: new D1AuthStore(env.DB),
      profiles: new D1ProfileStore(env.DB),
      rateLimiter: new D1RateLimiter(env.DB),
      email:
        env.RESEND_API_KEY && env.MAIL_FROM
          ? new ResendEmailSender({ apiKey: env.RESEND_API_KEY, from: env.MAIL_FROM })
          : new LogEmailSender(),
      ids: webIdSource,
      authConfig: { jwtSecret: env.JWT_SECRET },
    });
    return app.fetch(request, env, ctx);
  },
} satisfies ExportedHandler<Env>;
