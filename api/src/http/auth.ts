import { Hono, type MiddlewareHandler } from "hono";
import {
  ACCESS_TOKEN_SECONDS,
  CODE_SECONDS,
  MAX_CODE_ATTEMPTS,
  REFRESH_TOKEN_SECONDS,
  equalHashes,
  keyedHash,
  normaliseEmail,
  scopesFor,
} from "../domain/auth";
import { signJwt, verifyJwt } from "../domain/jwt";
import type { ClientType, Deps, Scope } from "../ports";
import { problem } from "./problem";
import { clientIp, isClientType, isCode, isEmail, onlyKeys, readBody } from "./validate";

const HOUR = 3600;
// Per email, per IP. Tunable; the spec says "rate limited per email and per IP".
const START_PER_EMAIL = 5;
const START_PER_IP = 15;
const VERIFY_PER_IP = 30;

/**
 * Cloudflare sets this header and strips any copy a client sends. Nothing else is trusted: `x-forwarded-for` is
 * spoofable. Off Cloudflare (the Node dev entry) it is whatever the caller sends; without it all callers share one
 * bucket.
 */

export type AuthVariables = { userId: string };

/** Requires a valid, unexpired access token with `scope`, for a user that still exists. */
export function requireScope(deps: Deps, scope: Scope): MiddlewareHandler<{ Variables: AuthVariables }> {
  return async (c, next) => {
    const unauthorized = () =>
      problem(c, 401, "unauthorized", "Sign in again", { "www-authenticate": 'Bearer realm="running-plan"' });
    const header = c.req.header("authorization") ?? "";
    const token = /^Bearer (.+)$/.exec(header)?.[1];
    if (!token) return unauthorized();
    const claims = await verifyJwt(token, deps.authConfig.jwtSecret, deps.clock.now().getTime() / 1000);
    if (!claims || typeof claims.sub !== "string" || !Array.isArray(claims.scp)) return unauthorized();
    // A deleted account must not keep working until its token expires.
    if (!(await deps.auth.userExists(claims.sub))) return unauthorized();
    // Signed in, but this token (for example a web one) may not do this.
    if (!claims.scp.includes(scope)) return problem(c, 403, "forbidden", "This token cannot do that");
    c.set("userId", claims.sub);
    await next();
  };
}

export function authRoutes(deps: Deps) {
  const app = new Hono<{ Variables: AuthVariables }>();

  async function issueTokens(userId: string, clientType: ClientType, scopes: Scope[], familyId: string, newAccount?: boolean) {
    const now = deps.clock.now();
    const nowSec = Math.floor(now.getTime() / 1000);
    const refreshToken = deps.ids.token();
    await deps.auth.saveRefresh({
      id: deps.ids.uuid(),
      userId,
      familyId,
      tokenHash: await keyedHash(deps.authConfig.jwtSecret, "refresh", refreshToken),
      clientType,
      scopes,
      createdAt: now.toISOString(),
      expiresAt: new Date((nowSec + REFRESH_TOKEN_SECONDS) * 1000).toISOString(),
      rotatedAt: null,
      revokedAt: null,
    });
    const accessToken = await signJwt(
      { sub: userId, scp: scopes, iat: nowSec, exp: nowSec + ACCESS_TOKEN_SECONDS },
      deps.authConfig.jwtSecret,
    );
    return {
      accessToken,
      refreshToken,
      tokenType: "Bearer" as const,
      expiresIn: ACCESS_TOKEN_SECONDS,
      scopes,
      userId,
      ...(newAccount ? { newAccount: true } : {}),
    };
  }

  app.post("/v1/auth/email/start", async (c) => {
    const body = await readBody(c.req.raw);
    if (!body || !onlyKeys(body, ["email"]) || !isEmail(body.email)) {
      return problem(c, 400, "bad_request", "Send a valid email address");
    }
    const email = normaliseEmail(body.email);
    const now = deps.clock.now();
    for (const [key, limit] of [
      [`start:email:${email}`, START_PER_EMAIL],
      [`start:ip:${clientIp(c.req.raw)}`, START_PER_IP],
    ] as const) {
      const result = await deps.rateLimiter.hit(key, limit, HOUR, now);
      if (!result.allowed) {
        return problem(c, 429, "rate_limited", "Too many requests", { "retry-after": String(result.retryAfterSec) });
      }
    }
    const code = deps.ids.code();
    await deps.auth.saveCode(
      email,
      await keyedHash(deps.authConfig.jwtSecret, "code", `${email}:${code}`),
      new Date(now.getTime() + CODE_SECONDS * 1000).toISOString(),
      now.toISOString(),
    );
    await deps.email.sendCode(email, code);
    return c.body(null, 202);
  });

  app.post("/v1/auth/email/verify", async (c) => {
    const body = await readBody(c.req.raw);
    if (
      !body ||
      !onlyKeys(body, ["email", "code", "clientType", "deviceName"]) ||
      !isEmail(body.email) ||
      !isCode(body.code) ||
      !isClientType(body.clientType) ||
      (body.deviceName !== undefined && (typeof body.deviceName !== "string" || body.deviceName.length > 64))
    ) {
      return problem(c, 400, "bad_request", "Send the email, the six digit code and the client type");
    }
    const email = normaliseEmail(body.email);
    const now = deps.clock.now();
    const limited = await deps.rateLimiter.hit(`verify:ip:${clientIp(c.req.raw)}`, VERIFY_PER_IP, HOUR, now);
    if (!limited.allowed) {
      return problem(c, 429, "rate_limited", "Too many requests", { "retry-after": String(limited.retryAfterSec) });
    }

    // One answer for every failure, so the response says nothing about which emails have codes.
    const invalid = () => problem(c, 401, "invalid_code", "That code is wrong or has expired");
    const saved = await deps.auth.getCode(email);
    if (!saved) return invalid();
    if (new Date(saved.expiresAt).getTime() <= now.getTime()) {
      await deps.auth.deleteCode(email);
      return invalid();
    }
    // Take the attempt before comparing, so parallel guesses cannot get past the limit.
    if (!(await deps.auth.useCodeAttempt(email, MAX_CODE_ATTEMPTS))) return invalid();
    const given = await keyedHash(deps.authConfig.jwtSecret, "code", `${email}:${body.code}`);
    if (!equalHashes(given, saved.codeHash)) return invalid();
    if (!(await deps.auth.deleteCode(email))) return invalid(); // a racing request used it first

    const { user, created } = await deps.auth.findOrCreateUser(email, deps.ids.uuid(), now.toISOString());
    const tokens = await issueTokens(user.id, body.clientType, scopesFor(body.clientType), deps.ids.uuid(), created);
    return c.json(tokens);
  });

  app.post("/v1/auth/refresh", async (c) => {
    const body = await readBody(c.req.raw);
    if (!body || !onlyKeys(body, ["refreshToken"]) || typeof body.refreshToken !== "string" || body.refreshToken.length === 0 || body.refreshToken.length > 512) {
      return problem(c, 400, "bad_request", "Send a refresh token");
    }
    const now = deps.clock.now();
    const unauthorized = () => problem(c, 401, "unauthorized", "Sign in again");
    const record = await deps.auth.findRefresh(await keyedHash(deps.authConfig.jwtSecret, "refresh", body.refreshToken));
    if (!record) return unauthorized();
    if (record.rotatedAt !== null || record.revokedAt !== null) {
      // A token that was already used is being replayed: assume it leaked and end the whole sign-in.
      await deps.auth.revokeFamily(record.familyId, now.toISOString());
      return unauthorized();
    }
    if (new Date(record.expiresAt).getTime() <= now.getTime()) return unauthorized();
    if (!(await deps.auth.markRefreshRotated(record.id, now.toISOString()))) {
      await deps.auth.revokeFamily(record.familyId, now.toISOString());
      return unauthorized();
    }
    return c.json(await issueTokens(record.userId, record.clientType, record.scopes, record.familyId));
  });

  app.delete("/v1/account", requireScope(deps, "app"), async (c) => {
    await deps.auth.deleteUser(c.get("userId"));
    return c.body(null, 204);
  });

  return app;
}
