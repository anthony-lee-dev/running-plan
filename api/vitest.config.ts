import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// Two projects: plain Node for domain, HTTP and config tests; the Workers runtime (workerd with a local D1)
// for adapter tests under test/adapters/cloudflare/. A third, `smoke`, exists only when SMOKE_URL is set
// (`npm run smoke`): it checks a deployed API over the network, so verify never runs it.
export default defineConfig({
  test: {
    projects: [
      {
        test: { name: "node", include: ["test/**/*.test.ts"], exclude: ["test/adapters/cloudflare/**"] },
      },
      {
        plugins: [
          cloudflareTest(async () => ({
            wrangler: { configPath: "./wrangler.toml" },
            miniflare: {
              bindings: { TEST_MIGRATIONS: await readD1Migrations(path.join(import.meta.dirname, "migrations")) },
            },
          })),
        ],
        test: { name: "d1", include: ["test/adapters/cloudflare/**/*.test.ts"] },
      },
      ...(process.env.SMOKE_URL ? [{ test: { name: "smoke", include: ["test/smoke/**/*.smoke.ts"], testTimeout: 30_000 } }] : []),
    ],
  },
});
