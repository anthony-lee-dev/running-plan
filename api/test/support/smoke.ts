// Smoke checks safe to run against the deployed API: no account, and nothing stored but the rate limiter's counters. They catch a
// deploy that has fallen behind `main` (an endpoint missing, an older engine) or is misconfigured (a missing secret
// or binding answers 500). `test/smoke-local.test.ts` runs them against the app in-process so they stay correct;
// `npm run smoke -w api` runs them against a URL.
import { describe, expect, it } from "vitest";
import { ENGINE_VERSION } from "../../src/domain/engine";
import { NOT_BUILT, GENERATE_BODY } from "./api-contract";
import { placeholderPath, responseErrors, spec, specOperations } from "./openapi";

type Fetch = (request: Request) => Response | Promise<Response>;

/** A fixed device id, so the deployed API rate limits smoke runs as one install. */
const SMOKE_DEVICE = "5a0c0de0-5a0c-4de0-8000-00000000000a";

const needsToken = (op: string) => {
  const [method, path] = op.split(" ") as [string, string];
  const security = spec.paths[path][method.toLowerCase()].security as unknown[] | undefined;
  return Boolean(security?.length);
};

export function smokeSuite(name: string, fetch: Fetch, base = "http://localhost") {
  const send = (method: string, path: string, init: RequestInit = {}) => fetch(new Request(`${base}${path}`, { method, ...init }));

  describe(`smoke (${name})`, () => {
    it("health: up, with storage answering", async () => {
      const res = await send("GET", "/v1/health");
      expect(await responseErrors("GET /v1/health", res.clone())).toEqual([]);
      expect(res.status).toBe(200);
      expect(((await res.json()) as { storage: boolean }).storage).toBe(true);
    });

    it("generate: a draft from the engine version on main", async () => {
      const res = await send("POST", "/v1/plans/generate", {
        headers: { "content-type": "application/json", "x-device-id": SMOKE_DEVICE },
        body: JSON.stringify(GENERATE_BODY),
      });
      expect(await responseErrors("POST /v1/plans/generate", res.clone())).toEqual([]);
      expect(res.status).toBe(200);
      expect(((await res.json()) as { engine: { version: string } }).engine.version).toBe(ENGINE_VERSION);
    });

    // The 401 sweep below only means "deployed" if an unknown path answers 404 rather than 401 without a token,
    // so the token check must sit on each route, not on a whole prefix.
    it("an unknown path under a signed-in prefix answers 404 without a token", async () => {
      const prefixes = ["/v1/plans/x", "/v1/sessions/x", "/v1/activities/x", "/v1/profile", "/v1/account"];
      const statuses = await Promise.all(prefixes.map(async (p) => `${p}/not-a-route ${(await send("GET", `${p}/not-a-route`)).status}`));
      expect(statuses).toEqual(prefixes.map((p) => `${p}/not-a-route 404`));
    });

    it("every built operation that needs a token is deployed: it answers 401, not 404", async () => {
      const ops = specOperations().filter((op) => !NOT_BUILT.has(op) && needsToken(op));
      expect(ops.length).toBeGreaterThan(0);
      const problems: string[] = [];
      for (const op of ops) {
        const [method, path] = op.split(" ") as [string, string];
        const res = await send(method, placeholderPath(path), method === "GET" || method === "DELETE" ? {} : {
          headers: { "content-type": "application/json" },
          body: "{}",
        });
        if (res.status !== 401) problems.push(`${op}: ${res.status}`);
        else problems.push(...(await responseErrors(op, res)));
      }
      expect(problems).toEqual([]);
    });
  });
}
