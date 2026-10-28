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
});
