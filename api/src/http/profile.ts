import { Hono } from "hono";
import { DEFAULT_PROFILE, applyProfileUpdate, parseProfileUpdate, type Profile } from "../domain/profile";
import type { Deps } from "../ports";
import { requireScope, type AuthVariables } from "./auth";
import { problem } from "./problem";

/** `If-Match: "7"` as 7; anything else (missing, unquoted, weak) is undefined. */
export function parseIfMatch(header: string | undefined): number | undefined {
  const match = /^"(\d{1,9})"$/.exec(header ?? "");
  return match ? Number(match[1]) : undefined;
}

export function profileRoutes(deps: Deps) {
  const app = new Hono<{ Variables: AuthVariables }>();
  app.use("/v1/profile", requireScope(deps, "app"));

  const respond = (profile: Profile) =>
    new Response(JSON.stringify(profile), {
      headers: { "content-type": "application/json", etag: `"${profile.revision}"` },
    });

  // A fixed time, so the default profile reads the same every time until it is first saved.
  const current = async (userId: string): Promise<Profile> =>
    (await deps.profiles.get(userId)) ?? { ...structuredClone(DEFAULT_PROFILE), revision: 1, updatedAt: "1970-01-01T00:00:00.000Z" };

  app.get("/v1/profile", async (c) => respond(await current(c.get("userId"))));

  app.patch("/v1/profile", async (c) => {
    const base = parseIfMatch(c.req.header("if-match"));
    if (base === undefined) return problem(c, 400, "bad_request", 'Send If-Match with the revision you edited, like "7"');
    const body: unknown = await c.req.json().catch(() => undefined);
    const parsed = parseProfileUpdate(body);
    if (!parsed.ok) return problem(c, 400, "validation_failed", "Some fields are invalid", {}, { errors: parsed.errors });

    const userId = c.get("userId");
    const before = await current(userId);
    if (before.revision !== base) {
      return problem(c, 409, "revision_conflict", "The profile changed since you loaded it", {}, { currentRevision: before.revision });
    }
    const { revision: _r, updatedAt: _u, ...fields } = before;
    const saved = await deps.profiles.save(userId, base, applyProfileUpdate(fields, parsed.value), deps.clock.now().toISOString());
    if (!saved.ok) {
      return problem(c, 409, "revision_conflict", "The profile changed since you loaded it", {}, { currentRevision: saved.currentRevision });
    }
    return respond(saved.profile);
  });

  return app;
}
