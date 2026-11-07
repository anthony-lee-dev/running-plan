import { env } from "cloudflare:workers";
import { applyD1Migrations } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { D1ActivityStore } from "../../../src/adapters/cloudflare/d1-activity-store";
import { D1AuthStore } from "../../../src/adapters/cloudflare/d1-auth-store";
import { D1CheckInStore } from "../../../src/adapters/cloudflare/d1-checkin-store";
import { D1ExportStore } from "../../../src/adapters/cloudflare/d1-export-store";
import { D1MatchStore } from "../../../src/adapters/cloudflare/d1-match-store";
import { D1PlanStore } from "../../../src/adapters/cloudflare/d1-plan-store";
import { accountExportStoreContract } from "../../support/export-store-contract";

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

const reset = async () => {
  await env.DB.prepare("DELETE FROM users").run();
};

accountExportStoreContract("D1", async () => ({
  store: new D1ExportStore(env.DB),
  auth: new D1AuthStore(env.DB),
  plans: new D1PlanStore(env.DB),
  activities: new D1ActivityStore(env.DB),
  matches: new D1MatchStore(env.DB),
  checkIns: new D1CheckInStore(env.DB),
  reset,
}));

// What the shared contract cannot reach: proposals have no store yet (task 2.14), and activities have no delete.
describe("D1ExportStore: proposals and tombstoned activities", () => {
  const NOW = "2026-10-29T09:00:00.000Z";
  const U1 = "00000000-0000-4000-8000-000000000001";
  const U2 = "00000000-0000-4000-8000-000000000002";
  const P1 = "00000000-0000-4000-8000-000000000101";
  const P2 = "00000000-0000-4000-8000-000000000102";
  const PR = (n: number) => `00000000-0000-4000-8000-0000000004${String(n).padStart(2, "0")}`;
  const store = new D1ExportStore(env.DB);

  const insertPlan = (id: string, userId: string, deletedAt: string | null = null) =>
    env.DB.prepare(
      `INSERT INTO plans (id, user_id, goal_type, start_date, week_count, source, adaptive, revision, content_revision, updated_at, deleted_at)
       VALUES (?, ?, '5k', '2026-10-26', 8, 'blank', 0, 1, 1, ?, ?)`,
    ).bind(id, userId, NOW, deletedAt);
  const insertProposal = (id: string, planId: string, userId: string, over: { deletedAt?: string | null; planChanges?: string | null; resolvedAt?: string | null; status?: string; urgent?: number; createdAt?: string } = {}) =>
    env.DB.prepare(
      `INSERT INTO proposals (id, plan_id, user_id, base_content_revision, kind, creator_type, creator_version, reason, urgent, changes, plan_changes, status, resolved_at, created_at, revision, updated_at, deleted_at)
       VALUES (?, ?, ?, 3, 'adjustment', 'rules', '1.0.0', 'Missed a key session', ?, '[{"op":"drop","sessionId":"x"}]', ?, ?, ?, ?, 1, ?, ?)`,
    ).bind(id, planId, userId, over.urgent ?? 1, over.planChanges ?? null, over.status ?? "pending", over.resolvedAt ?? null, over.createdAt ?? NOW, NOW, over.deletedAt ?? null);

  beforeEach(async () => {
    await reset();
    await new D1AuthStore(env.DB).findOrCreateUser("a@example.com", U1, NOW);
    await new D1AuthStore(env.DB).findOrCreateUser("b@example.com", U2, NOW);
  });

  it("maps a proposal to the spec's shape, and leaves out deleted ones, those of deleted plans and other users'", async () => {
    await env.DB.batch([
      insertPlan(P1, U1),
      insertPlan(P2, U1, NOW),
      insertProposal(PR(1), P1, U1, { planChanges: '{"weekCount":10}', status: "accepted", resolvedAt: NOW, urgent: 0, createdAt: "2026-10-30T09:00:00.000Z" }),
      insertProposal(PR(2), P1, U1),
      insertProposal(PR(3), P1, U1, { deletedAt: NOW }),
      insertProposal(PR(4), P2, U1),
      insertPlan("00000000-0000-4000-8000-000000000103", U2),
      insertProposal(PR(5), "00000000-0000-4000-8000-000000000103", U2),
    ]);
    const { proposals } = (await store.read(U1))!;
    expect(proposals.map((p) => p.id)).toEqual([PR(2), PR(1)]);
    expect(proposals[0]).toEqual({
      id: PR(2), planId: P1, baseContentRevision: 3, kind: "adjustment", creator: { type: "rules", version: "1.0.0" }, reason: "Missed a key session",
      urgent: true, changes: [{ op: "drop", sessionId: "x" }], status: "pending", createdAt: NOW, updatedAt: NOW, deletedAt: null, resolvedAt: null,
    });
    expect(proposals[1]).toMatchObject({ urgent: false, planChanges: { weekCount: 10 }, status: "accepted", resolvedAt: NOW });
  });

  it("leaves out a tombstoned activity", async () => {
    const activities = new D1ActivityStore(env.DB);
    const make = (id: string, n: number) => ({
      id, source: "apple_health" as const, externalId: `HK-${n}`, workoutType: "running" as const, startedAt: "2026-10-28T07:00:00-04:00",
      localDate: "2026-10-28", durationSec: 1800, disposition: "inbox" as const, importedAt: NOW, revision: 1, updatedAt: NOW,
    });
    const A1 = "00000000-0000-4000-8000-000000000901";
    const A2 = "00000000-0000-4000-8000-000000000902";
    await activities.applyImport(U1, [make(A1, 1), make(A2, 2)], []);
    await env.DB.prepare("UPDATE activities SET deleted_at = ? WHERE id = ?").bind(NOW, A2).run();
    expect((await store.read(U1))!.activities.map((a) => a.id)).toEqual([A1]);
  });
});
