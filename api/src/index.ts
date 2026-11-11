// Cloudflare Workers entry. The only place outside adapters/cloudflare that sees Cloudflare bindings.
import { createApp } from "./app";
import { CloudflareEmailSender, type SendBinding } from "./adapters/cloudflare/cloudflare-email";
import { D1ActivityStore } from "./adapters/cloudflare/d1-activity-store";
import { D1MatchStore } from "./adapters/cloudflare/d1-match-store";
import { D1CheckInStore } from "./adapters/cloudflare/d1-checkin-store";
import { D1AuthStore } from "./adapters/cloudflare/d1-auth-store";
import { D1ExportStore } from "./adapters/cloudflare/d1-export-store";
import { D1HealthProbe } from "./adapters/cloudflare/d1-health";
import { D1ProfileStore } from "./adapters/cloudflare/d1-profile-store";
import { D1PlanStore } from "./adapters/cloudflare/d1-plan-store";
import { D1SummaryStore } from "./adapters/cloudflare/d1-summary-store";
import { D1ProposalStore } from "./adapters/cloudflare/d1-proposal-store";
import { D1SyncStore } from "./adapters/cloudflare/d1-sync-store";
import { WorkersAiNarrator, type AiBinding } from "./adapters/cloudflare/workers-ai-narrator";
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
  /** Workers AI binding (`[ai]` in wrangler.toml): rewords run summaries. Without it the template is shown. */
  AI?: AiBinding;
  /** The kill switch for AI run summaries: "on" or "off" (anything else is off). */
  AI_SUMMARIES?: string;
  /** Model calls a day across all accounts. Default 600, about 60% of the Workers Free allowance at about 10 neurons a call; a value over 900 is ignored (raise FREE_POOL_CEILING with a move to Workers Paid). */
  AI_DAILY_CAP?: string;
}

const DEFAULT_DAILY_CAP = 600;
/** The ceiling for the Workers Free pool (about 10 neurons a call against 10,000 a day): a larger value is ignored, not trusted. */
const FREE_POOL_CEILING = 900;
const dailyCap = (value: string | undefined) => {
  const n = value !== undefined && /^\d{1,6}$/.test(value) ? Number(value) : DEFAULT_DAILY_CAP;
  return n > FREE_POOL_CEILING ? DEFAULT_DAILY_CAP : n;
};

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
      accountExport: new D1ExportStore(env.DB),
      plans: new D1PlanStore(env.DB),
      activities: new D1ActivityStore(env.DB),
      matches: new D1MatchStore(env.DB),
      checkIns: new D1CheckInStore(env.DB),
      summaries: new D1SummaryStore(env.DB),
      proposals: new D1ProposalStore(env.DB),
      sync: new D1SyncStore(env.DB),
      rateLimiter: new D1RateLimiter(env.DB),
      email:
        env.EMAIL && env.MAIL_FROM
          ? new CloudflareEmailSender({ binding: env.EMAIL, from: env.MAIL_FROM })
          : new LogEmailSender(),
      ids: webIdSource,
      authConfig: { jwtSecret: env.JWT_SECRET },
      ...(env.AI ? { narrator: new WorkersAiNarrator(env.AI) } : {}),
      summaryConfig: { aiEnabled: env.AI_SUMMARIES === "on", dailyCallCap: dailyCap(env.AI_DAILY_CAP) },
    });
    return app.fetch(request, env, ctx);
  },
} satisfies ExportedHandler<Env>;
