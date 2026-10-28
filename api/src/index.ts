// Cloudflare Workers entry. The only place outside adapters/cloudflare that sees Cloudflare bindings.
import { createApp } from "./app";
import { D1HealthProbe } from "./adapters/cloudflare/d1-health";
import { systemClock } from "./adapters/memory";

export interface Env {
  DB: D1Database;
}

export default {
  fetch(request: Request, env: Env, ctx: ExecutionContext) {
    const app = createApp({ clock: systemClock, health: new D1HealthProbe(env.DB) });
    return app.fetch(request, env, ctx);
  },
} satisfies ExportedHandler<Env>;
