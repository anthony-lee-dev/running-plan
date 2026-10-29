import { env } from "cloudflare:workers";
import { applyD1Migrations } from "cloudflare:test";
import { beforeAll } from "vitest";
import { D1AuthStore } from "../../../src/adapters/cloudflare/d1-auth-store";
import { D1ProfileStore } from "../../../src/adapters/cloudflare/d1-profile-store";
import { profileStoreContract } from "../../support/profile-store-contract";

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

profileStoreContract("D1", async () => ({
  store: new D1ProfileStore(env.DB),
  auth: new D1AuthStore(env.DB),
  reset: async () => {
    await env.DB.prepare("DELETE FROM users").run();
  },
}));
