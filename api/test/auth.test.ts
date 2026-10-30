import { beforeEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app";
import { MemoryAuthStore, MemoryEmailSender, memoryDeps } from "../src/adapters/memory";
import { signJwt, verifyJwt } from "../src/domain/jwt";
import type { Clock, Deps } from "../src/ports";

class ManualClock implements Clock {
  constructor(public at = new Date("2026-10-29T09:00:00Z")) {}
  now() {
    return this.at;
  }
  advance(seconds: number) {
    this.at = new Date(this.at.getTime() + seconds * 1000);
  }
}

const SECRET = "test-secret-test-secret-test-secret";
const EMAIL = "Runner@Example.com";

let clock: ManualClock;
let email: MemoryEmailSender;
let store: MemoryAuthStore;
let deps: Deps;
let app: ReturnType<typeof createApp>;

beforeEach(() => {
  clock = new ManualClock();
  email = new MemoryEmailSender();
  store = new MemoryAuthStore();
  deps = memoryDeps({ clock, email, auth: store, authConfig: { jwtSecret: SECRET } });
  app = createApp(deps);
});

const post = (path: string, body: unknown, headers: Record<string, string> = {}) =>
  app.request(path, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });

const start = (address = EMAIL, headers: Record<string, string> = {}) => post("/v1/auth/email/start", { email: address }, headers);
const verify = (code: string, clientType = "ios", address = EMAIL) =>
  post("/v1/auth/email/verify", { email: address, code, clientType });
const lastCode = () => email.sent.at(-1)!.code;

interface Tokens {
  accessToken: string;
  refreshToken: string;
  tokenType: string;
  expiresIn: number;
  scopes: string[];
  userId: string;
  newAccount?: boolean;
}

async function signIn(clientType = "ios", address = EMAIL): Promise<Tokens> {
  await start(address);
  const res = await verify(lastCode(), clientType, address);
  expect(res.status).toBe(200);
  return (await res.json()) as Tokens;
}

describe("POST /v1/auth/email/start", () => {
  it("answers 202 and emails a six digit code to the normalised address", async () => {
    const res = await start();
    expect(res.status).toBe(202);
    expect(email.sent).toHaveLength(1);
    expect(email.sent[0]!.to).toBe("runner@example.com");
    expect(email.sent[0]!.code).toMatch(/^[0-9]{6}$/);
  });

  it.each([
    ["no email", {}],
    ["not an email", { email: "nope" }],
    ["too long", { email: `${"a".repeat(250)}@example.com` }],
    ["unknown field", { email: "a@example.com", extra: 1 }],
    ["wrong type", { email: 5 }],
  ])("rejects %s with a 400 problem", async (_name, body) => {
    const res = await post("/v1/auth/email/start", body);
    expect(res.status).toBe(400);
    expect(res.headers.get("content-type")).toContain("application/problem+json");
    expect(email.sent).toHaveLength(0);
  });

  it("rejects a body that is not JSON", async () => {
    const res = await app.request("/v1/auth/email/start", { method: "POST", body: "nope" });
    expect(res.status).toBe(400);
  });

  it("does not store the code in clear", async () => {
    await start();
    const saved = await store.getCode("runner@example.com");
    expect(saved?.codeHash).not.toContain(lastCode());
  });

  it("limits requests per email, then per IP, with Retry-After", async () => {
    for (let i = 0; i < 5; i++) expect((await start()).status).toBe(202);
    const blocked = await start();
    expect(blocked.status).toBe(429);
    expect(Number(blocked.headers.get("retry-after"))).toBeGreaterThan(0);

    for (let i = 0; i < 15; i++) expect((await start(`user${i}@example.com`, { "cf-connecting-ip": "203.0.113.9" })).status).toBe(202);
    expect((await start("another@example.com", { "cf-connecting-ip": "203.0.113.9" })).status).toBe(429);
    expect((await start("another@example.com", { "cf-connecting-ip": "203.0.113.10" })).status).toBe(202);
  });

  it("allows another request once the window has passed", async () => {
    for (let i = 0; i < 5; i++) await start();
    expect((await start()).status).toBe(429);
    clock.advance(3601);
    expect((await start()).status).toBe(202);
  });
});

describe("POST /v1/auth/email/verify", () => {
  it("signs in with the code, creates the account and returns a token pair", async () => {
    const tokens = await signIn("ios");
    expect(tokens).toMatchObject({ tokenType: "Bearer", expiresIn: 900, scopes: ["app", "activities:write"], newAccount: true });
    expect(tokens.userId).toMatch(/^[0-9a-f-]{36}$/);
    expect(tokens.refreshToken.length).toBeGreaterThan(30);
    const claims = await verifyJwt(tokens.accessToken, SECRET, clock.now().getTime() / 1000);
    expect(claims).toMatchObject({ sub: tokens.userId, scp: ["app", "activities:write"] });
  });

  it("gives web clients no activities:write scope and android clients the native scopes", async () => {
    expect((await signIn("web")).scopes).toEqual(["app"]);
    expect((await signIn("android", "other@example.com")).scopes).toEqual(["app", "activities:write"]);
  });

  it("reuses the account on the next sign-in", async () => {
    const first = await signIn();
    clock.advance(1);
    const second = await signIn();
    expect(second.userId).toBe(first.userId);
    expect(second.newAccount).toBeFalsy();
  });

  it("accepts a code only once", async () => {
    await start();
    const code = lastCode();
    expect((await verify(code)).status).toBe(200);
    expect((await verify(code)).status).toBe(401);
  });

  it("rejects a wrong code, an unknown email and an expired code the same way", async () => {
    await start();
    const wrong = lastCode() === "000000" ? "111111" : "000000";
    const bad = await verify(wrong);
    expect(bad.status).toBe(401);
    const body = await bad.json();
    expect((await verify(lastCode(), "ios", "stranger@example.com")).status).toBe(401);
    expect(await (await verify(wrong, "ios", "stranger@example.com")).json()).toEqual(body);
    clock.advance(10 * 60);
    expect((await verify(lastCode())).status).toBe(401);
  });

  it("accepts the code up to just before ten minutes", async () => {
    await start();
    clock.advance(10 * 60 - 1);
    expect((await verify(lastCode())).status).toBe(200);
  });

  it("locks the code after five wrong attempts, even for the right code", async () => {
    await start();
    const right = lastCode();
    const wrong = right === "000000" ? "111111" : "000000";
    for (let i = 0; i < 5; i++) expect((await verify(wrong)).status).toBe(401);
    expect((await verify(right)).status).toBe(401);
  });

  it("a new code replaces the old one", async () => {
    await start();
    const first = lastCode();
    clock.advance(1);
    await start();
    const second = lastCode();
    if (first !== second) expect((await verify(first)).status).toBe(401);
    expect((await verify(second)).status).toBe(200);
  });

  it.each([
    ["short code", { email: EMAIL, code: "123", clientType: "ios" }],
    ["letters", { email: EMAIL, code: "12345a", clientType: "ios" }],
    ["bad client type", { email: EMAIL, code: "123456", clientType: "tv" }],
    ["no client type", { email: EMAIL, code: "123456" }],
    ["unknown field", { email: EMAIL, code: "123456", clientType: "ios", admin: true }],
  ])("rejects %s with 400", async (_name, body) => {
    expect((await post("/v1/auth/email/verify", body)).status).toBe(400);
  });

  it("limits verify attempts per IP", async () => {
    for (let i = 0; i < 30; i++) await post("/v1/auth/email/verify", { email: EMAIL, code: "000000", clientType: "ios" }, { "cf-connecting-ip": "198.51.100.7" });
    const res = await post("/v1/auth/email/verify", { email: EMAIL, code: "000000", clientType: "ios" }, { "cf-connecting-ip": "198.51.100.7" });
    expect(res.status).toBe(429);
  });
});

describe("POST /v1/auth/refresh", () => {
  const refresh = (token: string) => post("/v1/auth/refresh", { refreshToken: token });

  it("rotates: a new pair comes back and the old refresh token stops working", async () => {
    const first = await signIn("web");
    clock.advance(60);
    const res = await refresh(first.refreshToken);
    expect(res.status).toBe(200);
    const next = (await res.json()) as Tokens;
    expect(next.refreshToken).not.toBe(first.refreshToken);
    expect(next).toMatchObject({ tokenType: "Bearer", scopes: ["app"], userId: first.userId });
    expect(next.newAccount).toBeUndefined();
    expect((await refresh(first.refreshToken)).status).toBe(401);
  });

  it("revokes the whole family when a rotated token is reused", async () => {
    const first = await signIn();
    const second = (await (await refresh(first.refreshToken)).json()) as Tokens;
    expect((await refresh(first.refreshToken)).status).toBe(401); // reuse
    expect((await refresh(second.refreshToken)).status).toBe(401); // the family is gone
  });

  it("leaves other sign-ins alone when one family is revoked", async () => {
    const phone = await signIn("ios");
    clock.advance(1);
    const web = await signIn("web");
    await refresh(phone.refreshToken);
    await refresh(phone.refreshToken);
    expect((await refresh(web.refreshToken)).status).toBe(200);
  });

  it("rejects an expired, unknown or malformed refresh token", async () => {
    const first = await signIn();
    expect((await refresh("not-a-real-token")).status).toBe(401);
    expect((await post("/v1/auth/refresh", {})).status).toBe(400);
    expect((await post("/v1/auth/refresh", { refreshToken: "x".repeat(513) })).status).toBe(400);
    clock.advance(61 * 24 * 3600);
    expect((await refresh(first.refreshToken)).status).toBe(401);
  });

  it("does not store the refresh token in clear", async () => {
    const first = await signIn();
    expect(await store.findRefresh(first.refreshToken)).toBeUndefined();
  });
});

describe("DELETE /v1/account and bearer auth", () => {
  const del = (token?: string) =>
    app.request("/v1/account", { method: "DELETE", headers: token ? { authorization: `Bearer ${token}` } : {} });

  it("deletes the account, and its tokens stop working", async () => {
    const tokens = await signIn();
    expect((await del(tokens.accessToken)).status).toBe(204);
    expect(await store.userExists(tokens.userId)).toBe(false);
    expect((await del(tokens.accessToken)).status).toBe(401);
    expect((await post("/v1/auth/refresh", { refreshToken: tokens.refreshToken })).status).toBe(401);
  });

  it("answers 401 problem+json without a valid token", async () => {
    for (const token of [undefined, "garbage", ""]) {
      const res = await del(token);
      expect(res.status).toBe(401);
      expect(res.headers.get("content-type")).toContain("application/problem+json");
      expect(res.headers.get("www-authenticate")).toContain("Bearer");
    }
  });

  it("rejects an expired access token", async () => {
    const tokens = await signIn();
    clock.advance(900);
    expect((await del(tokens.accessToken)).status).toBe(401);
  });

  it("answers 403, not 401, for a signed-in token that lacks the scope", async () => {
    const tokens = await signIn();
    const nowSec = clock.now().getTime() / 1000;
    const noScope = await signJwt({ sub: tokens.userId, scp: ["activities:write"], exp: nowSec + 60 }, SECRET);
    const res = await del(noScope);
    expect(res.status).toBe(403);
    expect(res.headers.get("content-type")).toContain("application/problem+json");
    expect(await store.userExists(tokens.userId)).toBe(true);
  });

  it("answers 401 for a correctly signed token of a user that does not exist", async () => {
    const ghost = await signJwt({ sub: "00000000-0000-4000-8000-00000000dead", scp: ["app"], exp: clock.now().getTime() / 1000 + 60 }, SECRET);
    expect((await del(ghost)).status).toBe(401);
  });

  it("ignores a spoofed x-forwarded-for when limiting by IP", async () => {
    for (let i = 0; i < 15; i++) await start(`u${i}@example.com`, { "x-forwarded-for": `10.0.0.${i}` });
    expect((await start("late@example.com", { "x-forwarded-for": "10.9.9.9" })).status).toBe(429);
  });

  it("a refreshed web token still has no activities:write scope", async () => {
    const web = await signIn("web");
    const next = (await (await post("/v1/auth/refresh", { refreshToken: web.refreshToken })).json()) as Tokens;
    expect(next.scopes).toEqual(["app"]);
    const claims = await verifyJwt(next.accessToken, SECRET, clock.now().getTime() / 1000);
    expect(claims?.scp).toEqual(["app"]);
  });

  it("rejects a token signed with another secret", async () => {
    const tokens = await signIn();
    const other = createApp(memoryDeps({ clock, auth: store, email, authConfig: { jwtSecret: "a-different-secret-a-different-secret" } }));
    const res = await other.request("/v1/account", { method: "DELETE", headers: { authorization: `Bearer ${tokens.accessToken}` } });
    expect(res.status).toBe(401);
  });
});
