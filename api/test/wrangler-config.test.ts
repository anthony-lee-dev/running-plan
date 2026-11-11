import { describe, expect, it } from "vitest";
import wranglerToml from "../wrangler.toml?raw";

describe("wrangler.toml", () => {
  // Guards backlog 0.4. A fork fails here until it creates its own D1 database (see wrangler.toml).
  it("binds DB to a real D1 database id, not the placeholder", () => {
    const block = wranglerToml.split("[[d1_databases]]")[1] ?? "";
    expect(block).toMatch(/^binding = "DB"$/m);
    expect(block).toMatch(/^database_name = "running-plan"$/m);
    expect(block).toMatch(
      /^database_id = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"$/m,
    );
  });

  // The web app and /v1 must share one origin (no CORS, CSP connect-src 'self'), so the API Worker serves web/dist.
  it("serves the built web app, running the Worker first only for /v1/*", () => {
    const block = wranglerToml.split("[assets]")[1] ?? "";
    expect(block).toMatch(/^directory = "\.\.\/web\/dist"$/m);
    expect(block).toMatch(/^not_found_handling = "single-page-application"$/m);
    expect(block).toMatch(/^run_worker_first = \["\/v1\/\*"\]$/m);
  });

  // Issue #132: run summaries on Workers AI, with a kill switch the human can flip without a code change.
  it("binds Workers AI and sets the AI_SUMMARIES switch", () => {
    expect(wranglerToml).toMatch(/^\[ai\]\nbinding = "AI"$/m);
    // Ships off: the human turns it on after the legal wording review (#82) and the device check.
    expect(wranglerToml).toMatch(/^AI_SUMMARIES = "off"$/m);
  });
});
