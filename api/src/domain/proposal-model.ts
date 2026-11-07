// What a stored proposal holds (design §6.6), in the shape of `Proposal` in spec/openapi.yaml, plus the pure rules for
// accepting one. No I/O.
import type { EngineInfo, Goal, SessionContent, Week } from "./plan-input";

export type ProposalStatus = "pending" | "accepted" | "dismissed" | "stale";
export type ProposalKind = "adjustment" | "interview_rerun";

export type ProposalChangeRecord =
  | { op: "create"; sessionId: string; after: SessionContent; userOwned: boolean }
  | { op: "update"; sessionId: string; before: SessionContent; after: SessionContent; userOwned: boolean }
  | { op: "delete"; sessionId: string; before: SessionContent; userOwned: boolean };

/** Plan-level changes, mainly from an interview re-run. A field left out stays as it is. */
export interface ProposalPlanChanges {
  goal?: Goal;
  weekCount?: number;
  weeks?: Week[];
  engine?: EngineInfo;
}

export interface StoredProposal {
  id: string;
  planId: string;
  /** The plan `contentRevision` this was built on; the proposal is stale once that moves. */
  baseContentRevision: number;
  kind: ProposalKind;
  creator: { type: "rules" | "ai"; version: string };
  reason: string;
  urgent: boolean;
  changes: ProposalChangeRecord[];
  planChanges?: ProposalPlanChanges;
  status: ProposalStatus;
  createdAt: string;
  updatedAt: string;
  deletedAt: string | null;
  resolvedAt: string | null;
  /** Bumped on every status change. Internal. */
  revision: number;
  /** The engine's key for an adjustment; stops the same proposal being made twice. Internal. */
  key?: string;
}

/** The changes an accept applies: those on user-owned sessions only when the user opted in. */
export const acceptedChanges = (changes: ProposalChangeRecord[], includeUserOwned: boolean): ProposalChangeRecord[] =>
  changes.filter((c) => includeUserOwned || !c.userOwned);

/** Why an accept or dismiss did not happen. */
export type ProposalFailure = { ok: false; reason: "not_found" } | { ok: false; reason: "not_pending"; status: ProposalStatus };
