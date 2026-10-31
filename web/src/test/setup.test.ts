import { getConfig } from "@testing-library/react";

// The default 1 s wait for findBy*/waitFor failed on a busy CI runner ("explains a date outside the plan"),
// so waits get more time than a slow runner needs; a wait that is met returns at once.
describe("test setup", () => {
  it("lets findBy and waitFor wait several seconds", () => {
    expect(getConfig().asyncUtilTimeout).toBeGreaterThanOrEqual(5000);
  });
});
