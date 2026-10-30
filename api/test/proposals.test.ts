import fc from "fast-check";
import { describe, expect, it } from "vitest";
import {
  PROPOSAL_RULES_VERSION,
  proposeAdjustments,
  type CheckInInput,
  type MatchInput,
  type PlanInput,
  type ProposalDraft,
  type SessionInput,
} from "../src/domain/proposals";
import { sessionDistanceM } from "../src/domain/validators";

const TODAY = "2026-11-18"; // a Wednesday

const addDays = (date: string, days: number) => new Date(Date.parse(`${date}T00:00:00Z`) + days * 86_400_000).toISOString().slice(0, 10);

let n = 0;
function session(offsetDays: number, over: Partial<SessionInput> = {}): SessionInput {
  n += 1;
  return {
    id: `s${n}`,
    date: addDays(TODAY, offsetDays),
    type: "easy",
    title: "Easy run",
    key: false,
    status: "planned",
    owner: "system",
    steps: [{ kind: "work", goal: { type: "distance", value: 5000 }, target: { type: "effort", effort: "easy" } }],
    ...over,
  };
}

const plan = (sessions: SessionInput[], over: Partial<PlanInput> = {}): PlanInput => ({ adaptive: true, source: "rules", sessions, ...over });
const checkIn = (s: SessionInput, over: Partial<CheckInInput> = {}): CheckInInput => ({ sessionId: s.id, when: "after", feel: 3, effortFelt: 5, pain: false, ...over });
const propose = (p: PlanInput, checkIns: CheckInInput[] = [], matches: MatchInput[] = []) => proposeAdjustments({ plan: p, checkIns, matches, today: TODAY });

const kinds = (proposals: ProposalDraft[]) => proposals.map((p) => p.key.split(":")[0]);
const km = (s: { steps: SessionInput["steps"]; type: SessionInput["type"] }) => sessionDistanceM(s as never) / 1000;

describe("proposeAdjustments: shape and switches", () => {
  it("proposes nothing for a plan with nothing to say", () => {
    expect(propose(plan([session(-3, { status: "done" }), session(2), session(4)]))).toEqual([]);
  });

  it("is off when the plan is not adaptive (blank plans by default), whatever happened", () => {
    const missed = session(-2, { key: true, type: "long" });
    const pain = [checkIn(session(-1), { pain: true })];
    expect(propose(plan([missed], { adaptive: false }), pain)).toEqual([]);
  });

  it("is on for a blank plan the user opted in to", () => {
    const missed = session(-2, { key: true, type: "long" });
    expect(propose(plan([missed], { adaptive: true, source: "blank" }))).toHaveLength(1);
  });

  it("stamps every proposal with the rules version, a reason of at most 200 characters, and a stable key", () => {
    const missed = session(-2, { key: true, type: "long", title: "Long run" });
    const [p] = propose(plan([missed]));
    expect(p).toMatchObject({ kind: "adjustment", creator: { type: "rules", version: PROPOSAL_RULES_VERSION } });
    expect(p!.reason.length).toBeGreaterThan(0);
    expect(p!.reason.length).toBeLessThanOrEqual(200);
    expect(p!.key).toBe(`missed_key:${missed.id}`);
  });

  it("rejects a today that is not a calendar date", () => {
    expect(() => proposeAdjustments({ plan: plan([]), checkIns: [], matches: [], today: "18/11/2026" })).toThrow(RangeError);
  });
});

describe("a missed key session is dropped, not rescheduled", () => {
  it("proposes to delete a key session that was planned in the last two weeks and not done, and says it is urgent", () => {
    const missed = session(-2, { key: true, type: "long", title: "Long run" });
    const [p] = propose(plan([missed, session(3)]));
    expect(p).toMatchObject({ urgent: true });
    expect(p!.changes).toEqual([{ op: "delete", sessionId: missed.id, before: expect.objectContaining({ type: "long", date: missed.date }), userOwned: false }]);
    expect(p!.reason).toContain("Long run");
  });

  it("makes one proposal per missed session", () => {
    const a = session(-2, { key: true, type: "tempo" });
    const b = session(-9, { key: true, type: "long" });
    expect(kinds(propose(plan([a, b])))).toEqual(["missed_key", "missed_key"]);
  });

  it.each([
    ["a key session that was done", session(-2, { key: true, status: "done" })],
    ["a key session that was skipped on purpose", session(-2, { key: true, status: "skipped" })],
    ["a session that is not key", session(-2, { key: false })],
    ["a key session still to come", session(2, { key: true })],
    ["a key session today (the day is not over)", session(0, { key: true })],
    ["a key session from more than two weeks ago", session(-15, { key: true })],
  ])("proposes nothing for %s", (_name, s) => {
    expect(propose(plan([s]))).toEqual([]);
  });

  it("counts a confirmed match as done, but not a suggested one", () => {
    const s = session(-2, { key: true });
    expect(propose(plan([s]), [], [{ sessionId: s.id, status: "confirmed" }])).toEqual([]);
    expect(propose(plan([s]), [], [{ sessionId: s.id, status: "suggested" }])).toHaveLength(1);
  });

  it("includes a user-owned session but flags it locked", () => {
    const s = session(-2, { key: true, owner: "user" });
    expect(propose(plan([s]))[0]!.changes[0]).toMatchObject({ sessionId: s.id, userOwned: true });
  });
});

describe("date windows, at the edges", () => {
  it.each([
    [-14, true],
    [-15, false],
    [-1, true],
    [0, false],
  ])("a key session %i days from today is missed: %s", (offset, expected) => {
    expect(propose(plan([session(offset, { key: true })])).length).toBe(expected ? 1 : 0);
  });

  const painThen = (offset: number) => {
    const past = session(offset);
    return propose(plan([past, session(2)]), [checkIn(past, { pain: true })]).length;
  };
  it.each([
    [0, 1],
    [-7, 1],
    [-8, 0],
    [1, 0], // a check-in on a session that has not happened yet is ignored
  ])("pain on a session %i days from today gives %i proposals", (offset, count) => {
    expect(painThen(offset)).toBe(count);
  });

  it.each([
    [0, false],
    [1, true],
    [7, true],
    [8, false],
  ])("a session %i days from today is in next week: %s", (offset, expected) => {
    const past = [session(-6), session(-4), session(-2)];
    const target = session(offset);
    const ins = past.map((s) => checkIn(s, { effortFelt: 9 }));
    const changed = propose(plan([...past, target]), ins).flatMap((p) => p.changes.map((c) => c.sessionId));
    expect(changed.includes(target.id)).toBe(expected);
  });
});

describe("robustness", () => {
  it("counts a key session as done when the user checked in after it, even with no confirmed match", () => {
    const s = session(-2, { key: true });
    expect(propose(plan([s]), [checkIn(s)])).toEqual([]);
    expect(propose(plan([s]), [checkIn(s, { when: "before" })])).toHaveLength(1); // only an after check-in means it was done
  });

  it("counts several check-ins on one session once, the last one winning", () => {
    const past = [session(-6), session(-4)];
    const hardTwice = [checkIn(past[0]!, { effortFelt: 9 }), checkIn(past[0]!, { effortFelt: 9 }), checkIn(past[1]!)];
    expect(propose(plan([...past, session(2)]), hardTwice)).toEqual([]);
    const corrected = [checkIn(past[0]!, { effortFelt: 9 }), checkIn(past[0]!, { effortFelt: 3 }), checkIn(past[1]!, { effortFelt: 9 })];
    expect(propose(plan([...past, session(2)]), corrected)).toEqual([]);
    const keyed = propose(plan([...past, session(2)]), [checkIn(past[0]!, { effortFelt: 9 }), checkIn(past[1]!, { effortFelt: 9 })]);
    expect(keyed[0]!.key).toBe(`ease_week:${past.map((s) => s.id).sort().join("+")}`);
  });

  it("does not propose a change that leaves the session as it was", () => {
    const past = [session(-6), session(-4), session(-2)];
    const tiny = session(2, { steps: [{ kind: "work", goal: { type: "distance", value: 20 } }] }); // 21 m rounds back to 20
    const ins = past.map((s) => checkIn(s, { feel: 5, effortFelt: 3 }));
    expect(propose(plan([...past, tiny]), ins)).toEqual([]);
  });

  it("never turns a session into less than a short run, and never lengthens a step when easing", () => {
    const past = [session(-6), session(-4), session(-2)];
    const short = session(2, { steps: [{ kind: "work", goal: { type: "distance", value: 900 } }] });
    const [p] = propose(plan([...past, short]), past.map((s) => checkIn(s, { effortFelt: 9 })));
    const change = p!.changes[0]!;
    if (change.op !== "update") throw new Error("expected an update");
    expect(sessionDistanceM(change.after as never)).toBeGreaterThanOrEqual(800);
    expect(sessionDistanceM(change.after as never)).toBeLessThanOrEqual(900);
    const recovery = session(3, { type: "intervals", key: true, steps: [{ kind: "repeat", count: 10, steps: [{ kind: "work", goal: { type: "distance", value: 125 } }, { kind: "recovery", goal: { type: "distance", value: 60 } }] }] });
    const [q] = propose(plan([...past, recovery]), past.map((s) => checkIn(s, { effortFelt: 9 })));
    const c = q!.changes[0]!;
    if (c.op !== "update") throw new Error("expected an update");
    const step = (c.after.steps[0] as { steps: { goal: { value: number } }[] }).steps;
    expect(step[0]!.goal.value).toBeLessThan(125);
    expect(step[1]!.goal.value).toBeLessThanOrEqual(60);
  });

  it("scales time goals too", () => {
    const past = [session(-6), session(-4), session(-2)];
    const timed = session(2, { steps: [{ kind: "work", goal: { type: "time", value: 1800 } }] });
    const [p] = propose(plan([...past, timed]), past.map((s) => checkIn(s, { effortFelt: 9 })));
    const c = p!.changes[0]!;
    if (c.op !== "update") throw new Error("expected an update");
    expect((c.after.steps[0] as { goal: { value: number } }).goal.value).toBe(1530);
  });

  it("shares nothing with its input: changing the output leaves the plan alone", () => {
    const past = [session(-6), session(-4), session(-2)];
    const next = session(2, { steps: [{ kind: "work", goal: { type: "distance", value: 900 }, target: { type: "effort", effort: "easy" } }] });
    const input = plan([...past, next]);
    const copy = structuredClone(input);
    const [p] = propose(input, past.map((s) => checkIn(s, { effortFelt: 9 })));
    const c = p!.changes[0]!;
    if (c.op !== "update") throw new Error("expected an update");
    (c.after.steps[0] as { target: { effort: string } }).target.effort = "hard";
    (c.before.steps[0] as { goal: { value: number } }).goal.value = 1;
    expect(input).toEqual(copy);
  });

  it("copies only a session's content fields into before and after", () => {
    const s = { ...session(-2, { key: true }), revision: 4, planId: "p1", updatedAt: "2026-11-16T10:00:00Z", deletedAt: null } as SessionInput;
    const [p] = propose(plan([s]));
    expect(Object.keys(p!.changes[0]!.before).sort()).toEqual(["date", "key", "owner", "status", "steps", "title", "type"]);
  });

  it("turns a hard session into an easy run without its old notes", () => {
    const yesterday = session(-1);
    const hard = session(3, { type: "intervals", key: true, notes: "6 x 400 at 5K pace", steps: [{ kind: "repeat", count: 6, steps: [{ kind: "work", goal: { type: "distance", value: 400 } }] }] });
    const [p] = propose(plan([yesterday, hard]), [checkIn(yesterday, { pain: true })]);
    const c = p!.changes[0]!;
    if (c.op !== "update") throw new Error("expected an update");
    expect(c.after.notes).toBeUndefined();
    expect(c.before.notes).toBe("6 x 400 at 5K pace");
  });

  it("works for a plan whose source is ai, as for rules", () => {
    expect(propose(plan([session(-2, { key: true })], { source: "ai" }))).toHaveLength(1);
  });
});

describe("sessions that felt much harder than planned ease the next week", () => {
  const week = () => [session(1, { type: "easy" }), session(3, { type: "tempo", key: true, title: "Tempo run", steps: [{ kind: "work", goal: { type: "distance", value: 6000 } }] }), session(6, { type: "long", key: true, title: "Long run", steps: [{ kind: "work", goal: { type: "distance", value: 10000 } }] })];

  it("reduces next week's distances by 15% when two of the last three check-ins were much harder", () => {
    const past = [session(-6), session(-4), session(-2)];
    const next = week();
    const ins = [checkIn(past[0]!, { effortFelt: 9 }), checkIn(past[1]!, { effortFelt: 5 }), checkIn(past[2]!, { feel: 1, effortFelt: 8 })];
    const [p] = propose(plan([...past, ...next]), ins);
    expect(p!.key.startsWith("ease_week")).toBe(true);
    expect(p!.urgent).toBe(false);
    expect(p!.changes.map((c) => c.sessionId).sort()).toEqual(next.map((s) => s.id).sort());
    for (const change of p!.changes) {
      const before = next.find((s) => s.id === change.sessionId)!;
      if (change.op !== "update") throw new Error("expected an update");
      expect(km(change.after)).toBeCloseTo(km(before) * 0.85, 0);
      expect(change.after.type).toBe(before.type);
      expect(change.after.date).toBe(before.date);
    }
  });

  it("needs two hard ones among the last three, and ignores before-session check-ins", () => {
    const past = [session(-6), session(-4), session(-2)];
    const next = week();
    const one = [checkIn(past[0]!, { effortFelt: 9 }), checkIn(past[1]!), checkIn(past[2]!)];
    expect(propose(plan([...past, ...next]), one)).toEqual([]);
    const before = [checkIn(past[0]!, { effortFelt: 9, when: "before" }), checkIn(past[1]!, { effortFelt: 9, when: "before" }), checkIn(past[2]!)];
    expect(propose(plan([...past, ...next]), before)).toEqual([]);
  });

  it("only looks at the three most recent after-session check-ins", () => {
    const past = [session(-10), session(-9), session(-5), session(-4), session(-2)];
    const ins = [checkIn(past[0]!, { effortFelt: 9 }), checkIn(past[1]!, { effortFelt: 9 }), checkIn(past[2]!), checkIn(past[3]!), checkIn(past[4]!)];
    expect(propose(plan([...past, ...week()]), ins)).toEqual([]);
  });

  it("leaves done, skipped and further-away sessions alone, and does nothing when next week is empty", () => {
    const past = [session(-6), session(-4), session(-2)];
    const ins = past.map((s) => checkIn(s, { effortFelt: 9 }));
    const done = session(2, { status: "done" });
    const far = session(9);
    expect(propose(plan([...past, done, far]), ins)).toEqual([]);
  });

  it("includes a user-owned session in next week but flags it locked", () => {
    const past = [session(-6), session(-4), session(-2)];
    const mine = session(2, { owner: "user" });
    const ins = past.map((s) => checkIn(s, { effortFelt: 9 }));
    const [p] = propose(plan([...past, mine, session(4)]), ins);
    expect(p!.changes.find((c) => c.sessionId === mine.id)).toMatchObject({ userOwned: true });
  });
});

describe("pain reduces the load, with guidance", () => {
  it("proposes an urgent easier week: 30% less, with hard sessions turned into easy runs", () => {
    const yesterday = session(-1);
    const next = [session(1), session(3, { type: "intervals", key: true, title: "Intervals", steps: [{ kind: "warmup", goal: { type: "distance", value: 1000 } }, { kind: "repeat", count: 4, steps: [{ kind: "work", goal: { type: "distance", value: 400 } }, { kind: "recovery", goal: { type: "distance", value: 200 } }] }, { kind: "cooldown", goal: { type: "distance", value: 1000 } }] }), session(6, { type: "long", key: true, steps: [{ kind: "work", goal: { type: "distance", value: 10000 } }] })];
    const [p] = propose(plan([yesterday, ...next]), [checkIn(yesterday, { pain: true })]);
    expect(p).toMatchObject({ urgent: true });
    expect(p!.key.startsWith("pain")).toBe(true);
    expect(p!.reason).toMatch(/pain/i);
    expect(p!.reason).toMatch(/qualified professional/i);
    expect(p!.reason).not.toMatch(/diagnos|treat/i);
    const byId = new Map(p!.changes.map((c) => [c.sessionId, c]));
    const intervals = byId.get(next[1]!.id)!;
    if (intervals.op !== "update") throw new Error("expected an update");
    expect(intervals.after.type).toBe("easy");
    expect(intervals.after.key).toBe(false);
    expect(km(intervals.after)).toBeCloseTo(km(next[1]!) * 0.7, 0);
    const long = byId.get(next[2]!.id)!;
    if (long.op !== "update") throw new Error("expected an update");
    expect(long.after.type).toBe("long");
    expect(km(long.after)).toBeCloseTo(10 * 0.7, 0);
  });

  it("notices pain in a before-session check-in too, but not an old one", () => {
    const recent = session(-2);
    const old = session(-12);
    const next = [session(2)];
    expect(propose(plan([recent, ...next]), [checkIn(recent, { when: "before", pain: true })])).toHaveLength(1);
    expect(propose(plan([old, ...next]), [checkIn(old, { pain: true })])).toEqual([]);
  });

  it("is the only load proposal when the sessions also felt hard", () => {
    const past = [session(-6), session(-4), session(-1)];
    const ins = [checkIn(past[0]!, { effortFelt: 9 }), checkIn(past[1]!, { effortFelt: 9 }), checkIn(past[2]!, { pain: true, effortFelt: 9 })];
    const proposals = propose(plan([...past, session(2), session(5)]), ins);
    expect(kinds(proposals).filter((k) => k !== "missed_key")).toEqual(["pain"]);
  });

  it("comes with a missed-key proposal when both happened, each separately", () => {
    const missed = session(-3, { key: true, type: "long" });
    const yesterday = session(-1);
    const proposals = propose(plan([missed, yesterday, session(2)]), [checkIn(yesterday, { pain: true })]);
    expect(kinds(proposals).sort()).toEqual(["missed_key", "pain"]);
  });
});

describe("consistently easy sessions progress a little", () => {
  const easyIns = (sessions: SessionInput[]) => sessions.map((s) => checkIn(s, { feel: 5, effortFelt: 3 }));

  it("adds 5% to next week's easy and long runs after three easy check-ins in a row, and leaves hard sessions alone", () => {
    const past = [session(-6), session(-4), session(-2)];
    const easy = session(1);
    const long = session(6, { type: "long", key: true, steps: [{ kind: "work", goal: { type: "distance", value: 10000 } }] });
    const tempo = session(3, { type: "tempo", key: true });
    const [p] = propose(plan([...past, easy, tempo, long]), easyIns(past));
    expect(p!.key.startsWith("progress")).toBe(true);
    expect(p!.urgent).toBe(false);
    expect(p!.changes.map((c) => c.sessionId).sort()).toEqual([easy.id, long.id].sort());
    for (const c of p!.changes) {
      if (c.op !== "update") throw new Error("expected an update");
      const before = [easy, long].find((s) => s.id === c.sessionId)!;
      expect(km(c.after)).toBeGreaterThan(km(before));
      expect(km(c.after)).toBeLessThanOrEqual(km(before) * 1.05 + 0.1);
    }
  });

  it("needs three check-ins, all easy and felt good", () => {
    const past = [session(-6), session(-4), session(-2)];
    const next = [session(1), session(4)];
    expect(propose(plan([...past.slice(0, 2), ...next]), easyIns(past.slice(0, 2)))).toEqual([]);
    const mixed = [checkIn(past[0]!, { feel: 5, effortFelt: 3 }), checkIn(past[1]!, { feel: 3, effortFelt: 3 }), checkIn(past[2]!, { feel: 5, effortFelt: 3 })];
    expect(propose(plan([...past, ...next]), mixed)).toEqual([]);
    const noEffort = past.map((s) => checkIn(s, { feel: 5, effortFelt: undefined }));
    expect(propose(plan([...past, ...next]), noEffort)).toEqual([]);
  });

  it("does nothing while a key session is missed, because plans change before they progress", () => {
    const past = [session(-6), session(-4), session(-2)];
    const missed = session(-3, { key: true });
    const proposals = propose(plan([...past, missed, session(2)]), easyIns(past));
    expect(kinds(proposals)).toEqual(["missed_key"]);
  });
});

describe("proposeAdjustments: properties", () => {
  const typeArb = fc.constantFrom("easy" as const, "long" as const, "intervals" as const, "tempo" as const, "strength" as const, "rest" as const, "custom" as const);
  const sessionArb = fc
    .record({
      offset: fc.integer({ min: -20, max: 14 }),
      type: typeArb,
      key: fc.boolean(),
      status: fc.constantFrom("planned" as const, "done" as const, "skipped" as const),
      owner: fc.constantFrom("system" as const, "user" as const),
      metres: fc.integer({ min: 1000, max: 25_000 }),
    })
    .map(({ offset, type, key, status, owner, metres }) => ({
      id: "placeholder",
      date: addDays(TODAY, offset),
      type,
      key,
      status,
      owner,
      steps: metres % 3 === 0
        ? [
            { kind: "warmup" as const, goal: { type: "distance" as const, value: 600 } },
            { kind: "repeat" as const, count: 2 + (metres % 8), steps: [{ kind: "work" as const, goal: { type: "distance" as const, value: 100 + (metres % 700) } }, { kind: "recovery" as const, goal: { type: "time" as const, value: 30 + (metres % 120) } }] },
            { kind: "cooldown" as const, goal: { type: "distance" as const, value: 600 } },
          ]
        : [{ kind: "work" as const, goal: { type: "distance" as const, value: metres }, target: { type: "effort" as const, effort: "easy" as const } }],
    }));
  const inputArb = fc.record({
    sessions: fc.array(sessionArb, { maxLength: 12 }).map((list) => list.map((s, i) => ({ ...s, id: `x${i}` }))),
    adaptive: fc.boolean(),
    picks: fc.array(fc.record({ index: fc.nat(11), when: fc.constantFrom("before" as const, "after" as const), feel: fc.integer({ min: 1, max: 5 }), effortFelt: fc.option(fc.integer({ min: 1, max: 10 }), { nil: undefined }), pain: fc.boolean() }), { maxLength: 8 }),
    confirmed: fc.array(fc.nat(11), { maxLength: 4 }),
  });

  const build = (i: { sessions: SessionInput[]; adaptive: boolean; picks: { index: number; when: "before" | "after"; feel: number; effortFelt: number | undefined; pain: boolean }[]; confirmed: number[] }) => {
    const checkIns = i.picks.filter((p) => i.sessions[p.index]).map((p): CheckInInput => ({ sessionId: i.sessions[p.index]!.id, when: p.when, feel: p.feel, effortFelt: p.effortFelt, pain: p.pain }));
    const matches = i.confirmed.filter((c) => i.sessions[c]).map((c): MatchInput => ({ sessionId: i.sessions[c]!.id, status: "confirmed" }));
    return { plan: { adaptive: i.adaptive, source: "rules" as const, sessions: i.sessions }, checkIns, matches };
  };

  it("never edits its input, is deterministic, and is empty when adaptation is off", () => {
    fc.assert(
      fc.property(inputArb, (i) => {
        const { plan: p, checkIns, matches } = build(i);
        const copy = structuredClone({ p, checkIns, matches });
        const first = proposeAdjustments({ plan: p, checkIns, matches, today: TODAY });
        expect(proposeAdjustments({ plan: p, checkIns, matches, today: TODAY })).toEqual(first);
        expect({ p, checkIns, matches }).toEqual(copy);
        if (!i.adaptive) expect(first).toEqual([]);
      }),
      { numRuns: 300 },
    );
  });

  it("only touches real sessions, never a finished one except to drop a missed key session, and flags user-owned ones", () => {
    fc.assert(
      fc.property(inputArb, (i) => {
        const { plan: p, checkIns, matches } = build(i);
        const proposals = proposeAdjustments({ plan: p, checkIns, matches, today: TODAY });
        const byId = new Map(p.sessions.map((s) => [s.id, s]));
        const keys = new Set<string>();
        for (const proposal of proposals) {
          expect(keys.has(proposal.key)).toBe(false);
          keys.add(proposal.key);
          expect(proposal.reason.length).toBeGreaterThan(0);
          expect(proposal.reason.length).toBeLessThanOrEqual(200);
          expect(proposal.changes.length).toBeGreaterThan(0);
          for (const change of proposal.changes) {
            const s = byId.get(change.sessionId)!;
            expect(s).toBeDefined();
            expect(change.userOwned).toBe(s.owner === "user");
            expect(s.status).toBe("planned");
            if (change.op === "delete") {
              expect(proposal.key.startsWith("missed_key")).toBe(true);
              expect(s.key).toBe(true);
              expect(s.date < TODAY).toBe(true);
            } else {
              expect(s.date > TODAY && s.date <= addDays(TODAY, 7)).toBe(true);
              expect(["easy", "long", "intervals", "tempo"]).toContain(s.type);
              expect(change.after).not.toEqual(change.before);
              const ratio = km(change.after) / km(s);
              expect(ratio).toBeGreaterThanOrEqual(0.6);
              expect(ratio).toBeLessThanOrEqual(1.12); // 5%, plus rounding on short steps and sessions
            }
          }
        }
        // At most one load proposal at a time.
        expect(proposals.filter((x) => !x.key.startsWith("missed_key")).length).toBeLessThanOrEqual(1);
      }),
      { numRuns: 400 },
    );
  });
});
