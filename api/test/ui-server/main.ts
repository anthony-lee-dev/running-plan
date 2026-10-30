// Starts the UI-test API on 127.0.0.1 only (its `/__test` routes hand out sign-in codes, so never on the LAN).
// `npm run ui-test-server -w api`; `scripts/verify.sh ios` starts it for the UI tests.
import { serve } from "@hono/node-server";
import { buildUiTestServer } from "./app";

export const UI_TEST_PORT = 8790;
const { app } = buildUiTestServer();
serve({ fetch: app.fetch, hostname: "127.0.0.1", port: UI_TEST_PORT });
console.log(`ui-test api (in-memory) on http://127.0.0.1:${UI_TEST_PORT}`);
