import { beforeEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app";
import { FixedClock, MemoryEmailSender, memoryDeps } from "../src/adapters/memory";

const SECRET = "test-secret-test-secret-test-secret";
type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const P = id(101);
const TODAY = "2026-11-06"; // a Friday
const run = (sid: string, date: string, over: Json = {}) => ({ id: sid, date, type: "easy", key: false, steps: [{ kind: "work", goal: { type: "distance", value: 5000 }, target: { type: "effort", effort: "easy" } }], ...over });
const S_PAST = id(201);
const S_NEXT = id(202);
const S_NEXT2 = id(203);

let app: ReturnType<typeof createApp>;
let email: MemoryEmailSender;
let token: string;
let deps: ReturnType<typeof memoryDeps>;

async function signIn(address = "runner@example.com"): Promise<string> {
  const headers = { "content-type": "application/json" };
  await app.request("/v1/auth/email/start", { method: "POST", body: JSON.stringify({ email: address }), headers });
  const res = await app.request("/v1/auth/email/verify", { method: "POST", body: JSON.stringify({ email: address, code: email.sent.at(-1)!.code, clientType: "ios" }), headers });
  return ((await res.json()) as { accessToken: string }).accessToken;
}
const call = (method: string, path: string, body?: unknown, as: string | undefined = token, anonymous = false, headers: Record<string, string> = {}) =>
  app.request(path, {
    method,
    headers: { ...(!anonymous && as ? { authorization: `Bearer ${as}` } : {}), ...(body !== undefined ? { "content-type": "application/json" } : {}), ...headers },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
const json = async (res: Response) => (await res.json()) as Json;
const generate = (body: unknown = { today: TODAY }, planId = P, as: string | undefined = token) => call("POST", `/v1/plans/${planId}/proposals:generate`, body, as);
const setReview = async (frequency: string) => {
  const profile = await json(await call("GET", "/v1/profile"));
  await call("PATCH", "/v1/profile", { review: { frequency } }, token, false, { "if-match": `"${profile.revision}"` });
};
const pain = (checkInId: number, sessionId = S_PAST) => call("POST", `/v1/sessions/${sessionId}/checkins`, { id: id(checkInId), when: "after", feel: 2, effortFelt: 8, pain: true });
const plan = async () => json(await call("GET", `/v1/plans/${P}`));

beforeEach(async () => {
  email = new MemoryEmailSender();
  deps = memoryDeps({ email, authConfig: { jwtSecret: SECRET }, clock: new FixedClock(new Date(`${TODAY}T12:00:00Z`)) });
  app = createApp(deps);
  token = await signIn();
  await call("POST", "/v1/plans", {
    id: P, goal: { type: "5k", date: "2027-01-10" }, startDate: "2026-11-02", weekCount: 8, source: "rules", engine: { presetId: "5k", version: "0.2.0" }, adaptive: true,
    weeks: [{ index: 0, phase: "base" }], sessions: [run(S_PAST, "2026-11-03"), run(S_NEXT, "2026-11-10", { owner: "system" }), run(S_NEXT2, "2026-11-12", { owner: "system" })],
  });
});

describe("pain flag", () => {
  it("raises an urgent proposal at once under Weekly plus urgent (the default)", async () => {
    expect((await pain(301)).status).toBe(201);
    const list = await json(await call("GET", `/v1/plans/${P}/proposals`));
    expect(list.proposals).toMatchObject([{ kind: "adjustment", urgent: true, status: "pending", baseContentRevision: 1 }]);
    expect(list.proposals[0].changes.map((c: Json) => c.sessionId).sort()).toEqual([S_NEXT, S_NEXT2]);
  });

  it("does not raise it again for a repeat of the check-in, or for the same pain on a later generate", async () => {
    await pain(301);
    await pain(301);
    expect((await json(await generate())).proposals).toEqual([]);
    expect((await json(await call("GET", `/v1/plans/${P}/proposals`))).proposals).toHaveLength(1);
  });

  it("raises nothing under Weekly, After import or Off, and a later generate then finds it", async () => {
    await setReview("weekly");
    await pain(301);
    expect((await json(await call("GET", `/v1/plans/${P}/proposals`))).proposals).toEqual([]);
    expect((await json(await generate())).proposals).toMatchObject([{ urgent: true }]);
  });

  it("raises nothing for a check-in without the flag, and never fails the check-in", async () => {
    const res = await call("POST", `/v1/sessions/${S_PAST}/checkins`, { id: id(302), when: "after", feel: 3 });
    expect(res.status).toBe(201);
    expect((await json(await call("GET", `/v1/plans/${P}/proposals`))).proposals).toEqual([]);
    deps.proposals.usedKeys = async () => {
      throw new Error("down");
    };
    expect((await pain(303)).status).toBe(201);
  });

  it("is raised by the offline queue's check-in too", async () => {
    const res = await call("POST", "/v1/sync", { operations: [{ idempotencyKey: id(900), kind: "checkin.create", id: id(304), sessionId: S_PAST, data: { when: "after", feel: 2, pain: true } }] });
    const body = await json(res);
    expect(body.results[0].status).toBe("applied");
    expect(body.changes.proposals).toMatchObject([{ urgent: true, status: "pending" }]);
  });
});

describe("POST /v1/plans/{id}/proposals:generate", () => {
  it("makes no adjustment proposals when reviews are Off, but still makes an interview re-run", async () => {
    await pain(301);
    await setReview("off");
    expect((await json(await generate())).proposals).toEqual([]);
    const rerun = await json(await generate({ today: TODAY, interview: { goal: { distance: "10k" }, weeklyDistanceM: 20000 } }));
    expect(rerun.proposals).toMatchObject([{ kind: "interview_rerun", urgent: false }]);
  });

  it("makes none for a blank plan that is not adaptive", async () => {
    await call("PATCH", `/v1/plans/${P}`, { adaptive: false }, token, false, { "if-match": '"1"' });
    await setReview("weekly");
    await pain(301);
    expect((await json(await generate())).proposals).toEqual([]);
  });

  it("does not make a dismissed proposal again", async () => {
    await setReview("weekly");
    await pain(301);
    const [first] = (await json(await generate())).proposals;
    expect((await call("POST", `/v1/proposals/${first.id}:dismiss`)).status).toBe(200);
    expect((await json(await generate())).proposals).toEqual([]);
    expect((await json(await call("GET", `/v1/plans/${P}/proposals?status=dismissed`))).proposals).toHaveLength(1);
  });

  it("validates the body and the plan", async () => {
    expect((await generate({})).status).toBe(400);
    expect((await generate({ today: "2026-02-30" })).status).toBe(400);
    expect((await generate({ today: TODAY, extra: 1 })).status).toBe(400);
    const bad = await generate({ today: TODAY, interview: { goal: { distance: "marathon" } } });
    expect(bad.status).toBe(400);
    expect((await json(bad)).errors[0].path).toBe("/interview/goal/distance");
    expect((await generate({ today: TODAY }, id(999))).status).toBe(404);
    expect((await generate({ today: TODAY }, P, await signIn("other@example.com"))).status).toBe(404);
    expect((await call("POST", `/v1/plans/${P}/proposals:generate`, { today: TODAY }, undefined, true)).status).toBe(401);
  });

  it("an interview re-run past the last week says there is nothing to change", async () => {
    const res = await generate({ today: "2027-03-01", interview: { goal: { distance: "5k" } } });
    expect(res.status).toBe(400);
    expect((await json(res)).type).toBe("no_future_weeks");
  });

  it("an interview re-run keeps the past and user-owned sessions and never edits the plan until accepted", async () => {
    const mine = id(210);
    await call("POST", `/v1/plans/${P}/sessions`, run(mine, "2026-11-18"));
    const before = await plan();
    const res = await json(await generate({ today: TODAY, interview: { goal: { distance: "10k", date: "2027-01-10" }, weeklyDistanceM: 20000, runsPerWeek: 4 } }));
    const [proposal] = res.proposals;
    expect(proposal.baseContentRevision).toBe(before.contentRevision);
    expect(proposal.changes.some((c: Json) => c.sessionId === mine)).toBe(false);
    expect(proposal.changes.some((c: Json) => c.sessionId === S_PAST)).toBe(false);
    expect(await plan()).toEqual(before);

    const accepted = await json(await call("POST", `/v1/proposals/${proposal.id}:accept`));
    const dates = accepted.sessions.map((s: Json) => s.id);
    expect(dates).toContain(mine);
    expect(dates).toContain(S_PAST);
    expect(dates).not.toContain(S_NEXT);
    expect(accepted).toMatchObject({ goal: { type: "10k", date: "2027-01-10" }, revision: before.revision + 1, contentRevision: before.contentRevision + 1 });
    expect(accepted.engine.interview).toMatchObject({ goal: { distance: "10k" }, runsPerWeek: 4 });
    expect(accepted.sessions.filter((s: Json) => s.date > "2026-11-08" && s.owner === "system").length).toBeGreaterThan(5);
    // The new sessions are live, with their own ids, and the plan stays one week-aligned plan.
    expect(new Set(accepted.sessions.map((s: Json) => s.id)).size).toBe(accepted.sessions.length);
  });
});

describe("accept and dismiss", () => {
  it("applies changes to system sessions and skips user-owned ones unless asked", async () => {
    await call("PATCH", `/v1/sessions/${S_NEXT2}`, { title: "My long run" }, token, false, { "if-match": '"1"' }); // now user-owned
    await pain(301);
    const [proposal] = (await json(await call("GET", `/v1/plans/${P}/proposals`))).proposals;
    const owned = proposal.changes.find((c: Json) => c.sessionId === S_NEXT2);
    expect(owned.userOwned).toBe(true);
    const plain = await json(await call("POST", `/v1/proposals/${proposal.id}:accept`));
    const next = plain.sessions.find((s: Json) => s.id === S_NEXT);
    expect(next.steps[0].goal.value).toBeLessThan(5000);
    expect(plain.sessions.find((s: Json) => s.id === S_NEXT2).steps[0].goal.value).toBe(5000);
    expect(plain.contentRevision).toBe(proposal.baseContentRevision + 1);
  });

  it("applies the user-owned changes with includeUserOwned", async () => {
    await call("PATCH", `/v1/sessions/${S_NEXT2}`, { title: "My long run" }, token, false, { "if-match": '"1"' });
    await pain(301);
    const [proposal] = (await json(await call("GET", `/v1/plans/${P}/proposals`))).proposals;
    const done = await json(await call("POST", `/v1/proposals/${proposal.id}:accept`, { includeUserOwned: true }));
    expect(done.sessions.find((s: Json) => s.id === S_NEXT2)).toMatchObject({ owner: "user", title: "My long run" });
    expect(done.sessions.find((s: Json) => s.id === S_NEXT2).steps[0].goal.value).toBeLessThan(5000);
  });

  it("answers 409 once the plan moves, and for a proposal already decided", async () => {
    await pain(301);
    const [proposal] = (await json(await call("GET", `/v1/plans/${P}/proposals`))).proposals;
    await call("PATCH", `/v1/sessions/${S_NEXT}`, { notes: "mine" }, token, false, { "if-match": '"1"' });
    const stale = await call("POST", `/v1/proposals/${proposal.id}:accept`);
    expect(stale.status).toBe(409);
    expect((await json(stale)).type).toBe("stale_proposal");
    expect((await call("POST", `/v1/proposals/${proposal.id}:dismiss`)).status).toBe(409);
    expect((await json(await call("GET", `/v1/plans/${P}/proposals?status=stale`))).proposals).toHaveLength(1);
    expect((await json(await call("GET", `/v1/plans/${P}/proposals`))).proposals).toEqual([]);

    // A new one on the current plan: accept it, then it cannot be accepted or dismissed again.
    await setReview("weekly");
    const [fresh] = (await json(await generate({ today: TODAY, interview: { goal: { distance: "5k" } } }))).proposals;
    expect((await call("POST", `/v1/proposals/${fresh.id}:accept`)).status).toBe(200);
    const again = await call("POST", `/v1/proposals/${fresh.id}:accept`);
    expect(again.status).toBe(409);
    expect((await json(again)).type).toBe("proposal_not_pending"); // accepted is what it is, though the plan moved
  });

  it("answers 409 proposal_not_pending for a dismissed proposal", async () => {
    await pain(301);
    const [proposal] = (await json(await call("GET", `/v1/plans/${P}/proposals`))).proposals;
    expect((await call("POST", `/v1/proposals/${proposal.id}:dismiss`)).status).toBe(200);
    for (const action of ["accept", "dismiss"]) {
      const res = await call("POST", `/v1/proposals/${proposal.id}:${action}`);
      expect(res.status).toBe(409);
      expect((await json(res)).type).toBe("proposal_not_pending");
    }
  });

  it("is a 404 for another user's proposal, and for paths that are not a proposal action, even without a token", async () => {
    await pain(301);
    const [proposal] = (await json(await call("GET", `/v1/plans/${P}/proposals`))).proposals;
    const other = await signIn("other@example.com");
    expect((await call("POST", `/v1/proposals/${proposal.id}:accept`, undefined, other)).status).toBe(404);
    expect((await call("POST", `/v1/proposals/${proposal.id}:dismiss`, undefined, other)).status).toBe(404);
    expect((await call("GET", `/v1/plans/${P}/proposals`, undefined, other)).status).toBe(404);
    for (const path of ["/v1/proposals/nonsense", `/v1/proposals/${proposal.id}`, `/v1/proposals/${proposal.id}:reopen`, `/v1/proposals/${proposal.id}:accept:x`]) {
      expect((await call("POST", path, undefined, undefined, true)).status).toBe(404);
    }
    expect((await call("POST", `/v1/proposals/${proposal.id}:accept`, undefined, undefined, true)).status).toBe(401);
    expect((await call("POST", `/v1/proposals/${proposal.id}:dismiss`, undefined, undefined, true)).status).toBe(401);
    expect((await call("GET", `/v1/plans/${P}/proposals`, undefined, undefined, true)).status).toBe(401);
  });

  it("checks the accept body and the list filter", async () => {
    await pain(301);
    const [proposal] = (await json(await call("GET", `/v1/plans/${P}/proposals`))).proposals;
    const accept = `/v1/proposals/${proposal.id}:accept`;
    expect((await call("POST", accept, { includeUserOwned: "yes" })).status).toBe(400);
    expect((await call("POST", accept, { extra: 1 })).status).toBe(400);
    expect((await call("GET", `/v1/plans/${P}/proposals?status=bogus`)).status).toBe(400);
    expect((await call("POST", accept, {})).status).toBe(200);
  });

  it("deleting the plan removes its proposals from the list and tombstones them for sync", async () => {
    await pain(301);
    const current = await plan();
    await call("DELETE", `/v1/plans/${P}`, undefined, token, false, { "if-match": `"${current.revision}"` });
    const pulled = await json(await call("POST", "/v1/sync", { operations: [] }));
    expect(pulled.changes.proposals).toMatchObject([{ deletedAt: expect.any(String) }]);
  });
});
