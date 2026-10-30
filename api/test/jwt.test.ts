import { describe, expect, it } from "vitest";
import { signJwt, verifyJwt } from "../src/domain/jwt";

const SECRET = "unit-test-secret-unit-test-secret";
const now = 1_800_000_000;

describe("HS256 JWT", () => {
  it("round-trips a payload", async () => {
    const token = await signJwt({ sub: "u1", scp: ["app"], exp: now + 60 }, SECRET);
    expect(token.split(".")).toHaveLength(3);
    expect(await verifyJwt(token, SECRET, now)).toMatchObject({ sub: "u1", scp: ["app"] });
  });
  it("rejects a wrong secret, a tampered payload and a tampered signature", async () => {
    const token = await signJwt({ sub: "u1", exp: now + 60 }, SECRET);
    expect(await verifyJwt(token, "another-secret-another-secret!!", now)).toBeUndefined();
    const [h, p, s] = token.split(".");
    const forged = btoa(JSON.stringify({ sub: "u2", exp: now + 60 })).replace(/=+$/, "");
    expect(await verifyJwt(`${h}.${forged}.${s}`, SECRET, now)).toBeUndefined();
    expect(await verifyJwt(`${h}.${p}.${s!.slice(0, -2)}AA`, SECRET, now)).toBeUndefined();
  });
  it("rejects an expired token and treats the expiry second as expired", async () => {
    const token = await signJwt({ sub: "u1", exp: now + 60 }, SECRET);
    expect(await verifyJwt(token, SECRET, now + 59)).toBeDefined();
    expect(await verifyJwt(token, SECRET, now + 60)).toBeUndefined();
  });
  it("rejects a token with no expiry, another algorithm, or garbage", async () => {
    expect(await verifyJwt(await signJwt({ sub: "u1" }, SECRET), SECRET, now)).toBeUndefined();
    const none = `${btoa('{"alg":"none","typ":"JWT"}').replace(/=+$/, "")}.${btoa('{"sub":"u1","exp":9999999999}').replace(/=+$/, "")}.`;
    expect(await verifyJwt(none, SECRET, now)).toBeUndefined();
    expect(await verifyJwt("not-a-token", SECRET, now)).toBeUndefined();
    expect(await verifyJwt("", SECRET, now)).toBeUndefined();
  });
});
