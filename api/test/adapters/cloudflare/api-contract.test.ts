// The contract suite against the Workers entry (`src/index.ts`) with a local D1. The email binding is a fake that
// keeps what it was asked to send, so the suite reads codes from it; the entry itself has no test hooks.
import { env } from "cloudflare:workers";
import { applyD1Migrations } from "cloudflare:test";
import { beforeAll } from "vitest";
import worker from "../../../src/index";
import { apiContract } from "../../support/api-contract";

const ctx = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;
const SECRET = "contract-test-secret-contract-test-secret";

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

apiContract("Workers, D1", async () => {
  const sent: { to: string; subject: string }[] = [];
  const EMAIL = { send: async (m: { to: string; subject: string }) => void sent.push(m) };
  return {
    fetch: (request) => worker.fetch(request, { DB: env.DB, JWT_SECRET: SECRET, EMAIL, MAIL_FROM: "plans@example.com" }, ctx),
    lastCode: (to) => /code is (\d{6})$/.exec(sent.filter((m) => m.to === to).at(-1)!.subject)![1]!,
    reset: async () => {
      await env.DB.batch([env.DB.prepare("DELETE FROM users"), env.DB.prepare("DELETE FROM rate_limits"), env.DB.prepare("DELETE FROM email_codes")]);
    },
  };
});
