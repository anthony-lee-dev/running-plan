// Starts the UI-test API on 127.0.0.1 only (its `/__test` routes hand out sign-in codes, so never on the LAN).
// `npm run ui-test-server -w api` listens on 8790; `scripts/verify.sh ios` sets UI_TEST_PORT=0 for any free port
// and reads the URL from the line printed below.
import { serve } from "@hono/node-server";
import { buildUiTestServer } from "./app";

const { app } = buildUiTestServer();
serve({ fetch: app.fetch, hostname: "127.0.0.1", port: Number(process.env.UI_TEST_PORT || 8790) }, (info) => {
  console.log(`ui-test api (in-memory) on http://127.0.0.1:${info.port}`);
});
