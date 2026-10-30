import { describe, expect, it, vi } from "vitest";
import { ApiError, createApi, type TokenStore, type Tokens } from "./client";

class MemoryTokens implements TokenStore {
  constructor(public value: Tokens | null = null) {}
  load() {
    return this.value;
  }
  save(tokens: Tokens | null) {
    this.value = tokens;
  }
}

type Handler = (req: { url: string; method: string; headers: Headers; body: unknown }) => Response | Promise<Response>;

function fakeFetch(handler: Handler) {
  const calls: { url: string; method: string; headers: Headers; body: unknown }[] = [];
  const fetcher = (async (input: string, init: RequestInit = {}) => {
    const req = { url: input, method: init.method ?? "GET", headers: new Headers(init.headers), body: init.body ? JSON.parse(init.body as string) : undefined };
    calls.push(req);
    return handler(req);
  }) as unknown as typeof fetch;
  return { fetcher, calls };
}

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });
const problem = (status: number, type: string, extra: object = {}) =>
  new Response(JSON.stringify({ type, title: type, status, ...extra }), { status, headers: { "content-type": "application/problem+json" } });
const pair = (n: number) => ({ accessToken: `access-${n}`, refreshToken: `refresh-${n}`, tokenType: "Bearer", expiresIn: 900, scopes: ["app"], userId: "u1" });

describe("sign in", () => {
  it("asks for a code by email, then verifies it as a web client and keeps the tokens", async () => {
    const tokens = new MemoryTokens();
    const { fetcher, calls } = fakeFetch((req) => (req.url.endsWith("/start") ? new Response(null, { status: 202 }) : json(pair(1))));
    const api = createApi({ fetch: fetcher, tokens });
    expect(api.isSignedIn()).toBe(false);
    await api.startSignIn("runner@example.com");
    await api.verifySignIn("runner@example.com", "123456");
    expect(calls[0]).toMatchObject({ url: "/v1/auth/email/start", method: "POST", body: { email: "runner@example.com" } });
    expect(calls[1]).toMatchObject({ url: "/v1/auth/email/verify", body: { email: "runner@example.com", code: "123456", clientType: "web" } });
    expect(tokens.value).toEqual({ accessToken: "access-1", refreshToken: "refresh-1" });
    expect(api.isSignedIn()).toBe(true);
  });

  it("raises an ApiError with the problem for a wrong code or a rate limit", async () => {
    const { fetcher } = fakeFetch(() => problem(401, "invalid_code"));
    const api = createApi({ fetch: fetcher, tokens: new MemoryTokens() });
    await expect(api.verifySignIn("a@example.com", "000000")).rejects.toMatchObject({ status: 401, problem: { type: "invalid_code" } });
    const limited = createApi({ fetch: fakeFetch(() => problem(429, "rate_limited")).fetcher, tokens: new MemoryTokens() });
    await expect(limited.startSignIn("a@example.com")).rejects.toBeInstanceOf(ApiError);
  });

  it("signing out forgets the tokens", () => {
    const tokens = new MemoryTokens({ accessToken: "a", refreshToken: "r" });
    const api = createApi({ fetch: fakeFetch(() => json({})).fetcher, tokens });
    api.signOut();
    expect(tokens.value).toBeNull();
    expect(api.isSignedIn()).toBe(false);
  });
});

describe("authorised requests", () => {
  it("send the access token", async () => {
    const { fetcher, calls } = fakeFetch(() => json({ plans: [] }));
    await createApi({ fetch: fetcher, tokens: new MemoryTokens({ accessToken: "tok", refreshToken: "r" }) }).listPlans();
    expect(calls[0]!.headers.get("authorization")).toBe("Bearer tok");
  });

  it("follow the cursor until the list is complete", async () => {
    const { fetcher, calls } = fakeFetch((req) =>
      req.url.includes("cursor=c2") ? json({ plans: [{ id: "p3" }] }) : req.url.includes("cursor=c1") ? json({ plans: [{ id: "p2" }], nextCursor: "c2" }) : json({ plans: [{ id: "p1" }], nextCursor: "c1" }),
    );
    const plans = await createApi({ fetch: fetcher, tokens: new MemoryTokens({ accessToken: "t", refreshToken: "r" }) }).listPlans();
    expect(plans.map((p) => p.id)).toEqual(["p1", "p2", "p3"]);
    expect(calls).toHaveLength(3);
  });

  it("get a plan by id", async () => {
    const { fetcher, calls } = fakeFetch(() => json({ id: "p1", sessions: [] }));
    await createApi({ fetch: fetcher, tokens: new MemoryTokens({ accessToken: "t", refreshToken: "r" }) }).getPlan("p1");
    expect(calls[0]!.url).toBe("/v1/plans/p1");
  });
});

describe("expired access tokens", () => {
  it("refresh once, keep the new pair, and retry the request", async () => {
    const tokens = new MemoryTokens({ accessToken: "old", refreshToken: "refresh-0" });
    const { fetcher, calls } = fakeFetch((req) => {
      if (req.url === "/v1/auth/refresh") return json(pair(1));
      return req.headers.get("authorization") === "Bearer access-1" ? json({ plans: [] }) : problem(401, "unauthorized");
    });
    await createApi({ fetch: fetcher, tokens }).listPlans();
    expect(calls.map((c) => c.url)).toEqual(["/v1/plans", "/v1/auth/refresh", "/v1/plans"]);
    expect(calls[1]!.body).toEqual({ refreshToken: "refresh-0" });
    expect(tokens.value).toEqual({ accessToken: "access-1", refreshToken: "refresh-1" });
  });

  it("share one refresh between requests that fail together", async () => {
    const tokens = new MemoryTokens({ accessToken: "old", refreshToken: "refresh-0" });
    const { fetcher, calls } = fakeFetch((req) => {
      if (req.url === "/v1/auth/refresh") return json(pair(1));
      return req.headers.get("authorization") === "Bearer access-1" ? json({ id: "p", sessions: [] }) : problem(401, "unauthorized");
    });
    const api = createApi({ fetch: fetcher, tokens });
    await Promise.all([api.getPlan("a"), api.getPlan("b"), api.getPlan("c")]);
    expect(calls.filter((c) => c.url === "/v1/auth/refresh")).toHaveLength(1);
  });

  it("sign the user out when the refresh token no longer works", async () => {
    const tokens = new MemoryTokens({ accessToken: "old", refreshToken: "dead" });
    const onSignedOut = vi.fn();
    const { fetcher } = fakeFetch(() => problem(401, "unauthorized"));
    const api = createApi({ fetch: fetcher, tokens, onSignedOut });
    await expect(api.listPlans()).rejects.toMatchObject({ status: 401 });
    expect(tokens.value).toBeNull();
    expect(onSignedOut).toHaveBeenCalledTimes(1);
  });

  it("keep the user signed in when the refresh fails with a server fault or a rate limit", async () => {
    for (const status of [500, 503, 429]) {
      const tokens = new MemoryTokens({ accessToken: "old", refreshToken: "r" });
      const onSignedOut = vi.fn();
      const { fetcher } = fakeFetch((req) => (req.url === "/v1/auth/refresh" ? problem(status, "oops") : problem(401, "unauthorized")));
      await expect(createApi({ fetch: fetcher, tokens, onSignedOut }).listPlans()).rejects.toMatchObject({ status });
      expect(tokens.value).toEqual({ accessToken: "old", refreshToken: "r" });
      expect(onSignedOut).not.toHaveBeenCalled();
    }
  });

  it("retry with the new token, without refreshing again, when another request already refreshed", async () => {
    const tokens = new MemoryTokens({ accessToken: "old", refreshToken: "refresh-0" });
    const { fetcher, calls } = fakeFetch((req) => {
      if (req.url === "/v1/auth/refresh") return json(pair(1));
      if (req.headers.get("authorization") === "Bearer access-1") return json({ plans: [] });
      // The first request is answered late, after a sibling has already swapped the tokens.
      if (req.url === "/v1/plans") tokens.save({ accessToken: "access-1", refreshToken: "refresh-1" });
      return problem(401, "unauthorized");
    });
    await createApi({ fetch: fetcher, tokens }).listPlans();
    expect(calls.filter((c) => c.url === "/v1/auth/refresh")).toHaveLength(0);
  });

  it("do not loop when the retry is refused too", async () => {
    const tokens = new MemoryTokens({ accessToken: "old", refreshToken: "r" });
    const { fetcher, calls } = fakeFetch((req) => (req.url === "/v1/auth/refresh" ? json(pair(1)) : problem(401, "unauthorized")));
    await expect(createApi({ fetch: fetcher, tokens }).listPlans()).rejects.toMatchObject({ status: 401 });
    expect(calls.filter((c) => c.url === "/v1/auth/refresh")).toHaveLength(1);
  });

  it("have nothing to refresh with when signed out", async () => {
    const { fetcher, calls } = fakeFetch(() => problem(401, "unauthorized"));
    await expect(createApi({ fetch: fetcher, tokens: new MemoryTokens() }).listPlans()).rejects.toMatchObject({ status: 401 });
    expect(calls).toHaveLength(1);
  });
});

describe("editing a session", () => {
  const session = { id: "s1", revision: 3 };

  it("sends the body with the base revision in If-Match", async () => {
    const { fetcher, calls } = fakeFetch(() => json({ session: { ...session, revision: 4, status: "done" }, planContentRevision: 9, warnings: [] }));
    const result = await createApi({ fetch: fetcher, tokens: new MemoryTokens({ accessToken: "t", refreshToken: "r" }) }).updateSession(session, { status: "done" });
    expect(calls[0]).toMatchObject({ url: "/v1/sessions/s1", method: "PATCH", body: { status: "done" } });
    expect(calls[0]!.headers.get("if-match")).toBe('"3"');
    expect(calls[0]!.headers.get("content-type")).toBe("application/json");
    expect(result.session.revision).toBe(4);
  });

  it("raises a 409 ApiError carrying the current revision", async () => {
    const { fetcher } = fakeFetch(() => problem(409, "revision_conflict", { currentRevision: 5 }));
    const error = await createApi({ fetch: fetcher, tokens: new MemoryTokens({ accessToken: "t", refreshToken: "r" }) }).updateSession(session, { status: "done" }).catch((e: ApiError) => e);
    expect(error).toBeInstanceOf(ApiError);
    expect(error).toMatchObject({ status: 409, problem: { currentRevision: 5 } });
  });
});
