// A small typed client for the Running Planner API (spec/openapi.yaml). The web app is online-first (design §9):
// every change goes to the server with the revision it was made against, and a conflict is shown, never merged.
import type { PlanDetail, PlanSummary, Problem, Session, SessionUpdate, SessionWriteResult } from "./types";

export interface Tokens {
  accessToken: string;
  refreshToken: string;
}

export interface TokenStore {
  load(): Tokens | null;
  save(tokens: Tokens | null): void;
}

/** Tokens live in sessionStorage: they end with the tab and are never shared with other tabs or sites. */
export class SessionTokenStore implements TokenStore {
  private static readonly KEY = "running-plan.tokens";
  load(): Tokens | null {
    try {
      const raw = sessionStorage.getItem(SessionTokenStore.KEY);
      return raw ? (JSON.parse(raw) as Tokens) : null;
    } catch {
      return null;
    }
  }
  save(tokens: Tokens | null): void {
    try {
      if (tokens) sessionStorage.setItem(SessionTokenStore.KEY, JSON.stringify(tokens));
      else sessionStorage.removeItem(SessionTokenStore.KEY);
    } catch {
      // Storage can be blocked; the session then lasts until the page reloads.
    }
  }
}

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly problem?: Problem,
  ) {
    super(problem?.title ?? `HTTP ${status}`);
  }
}

export interface Api {
  isSignedIn(): boolean;
  startSignIn(email: string): Promise<void>;
  verifySignIn(email: string, code: string): Promise<void>;
  signOut(): void;
  listPlans(): Promise<PlanSummary[]>;
  getPlan(id: string): Promise<PlanDetail>;
  /** Edits a session against the revision the caller loaded it at. */
  updateSession(session: Pick<Session, "id" | "revision">, body: SessionUpdate): Promise<SessionWriteResult>;
}

export interface ApiOptions {
  fetch?: typeof fetch;
  tokens: TokenStore;
  /** Called when the refresh token stops working, so the app can show the sign-in form. */
  onSignedOut?: () => void;
  baseUrl?: string;
}

async function toError(response: Response): Promise<ApiError> {
  const problem = (await response.json().catch(() => undefined)) as Problem | undefined;
  return new ApiError(response.status, problem);
}

export function createApi(options: ApiOptions): Api {
  const doFetch = options.fetch ?? ((...args: Parameters<typeof fetch>) => fetch(...args));
  const base = options.baseUrl ?? "";
  let refreshing: Promise<boolean> | undefined;

  const send = (path: string, method: string, body?: unknown, headers: Record<string, string> = {}, token?: string) =>
    doFetch(`${base}${path}`, {
      method,
      headers: { ...(body !== undefined ? { "content-type": "application/json" } : {}), ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers },
      ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
    });

  /** One refresh at a time: requests that fail together wait for the same new token pair. */
  function refresh(): Promise<boolean> {
    refreshing ??= (async () => {
      const current = options.tokens.load();
      if (!current) return false;
      const response = await send("/v1/auth/refresh", "POST", { refreshToken: current.refreshToken });
      if (!response.ok) {
        // Only a refusal ends the session. A server fault (5xx) or a rate limit keeps the tokens for a retry.
        if (response.status === 400 || response.status === 401) {
          options.tokens.save(null);
          options.onSignedOut?.();
          return false;
        }
        throw await toError(response);
      }
      const next = (await response.json()) as Tokens;
      options.tokens.save({ accessToken: next.accessToken, refreshToken: next.refreshToken });
      return true;
    })().finally(() => {
      refreshing = undefined;
    });
    return refreshing;
  }

  async function authorised<T>(path: string, method: string, body?: unknown, headers?: Record<string, string>): Promise<T> {
    const used = options.tokens.load()?.accessToken;
    let response = await send(path, method, body, headers, used);
    if (response.status === 401 && options.tokens.load()) {
      // If another request already refreshed while this one was in flight, just retry with the new token.
      const renewed = options.tokens.load()?.accessToken !== used || (await refresh());
      if (renewed) response = await send(path, method, body, headers, options.tokens.load()?.accessToken);
    }
    if (!response.ok) throw await toError(response);
    return (response.status === 204 ? undefined : await response.json()) as T;
  }

  return {
    isSignedIn: () => options.tokens.load() !== null,
    async startSignIn(email) {
      const response = await send("/v1/auth/email/start", "POST", { email });
      if (!response.ok) throw await toError(response);
    },
    async verifySignIn(email, code) {
      const response = await send("/v1/auth/email/verify", "POST", { email, code, clientType: "web" });
      if (!response.ok) throw await toError(response);
      const pair = (await response.json()) as Tokens;
      options.tokens.save({ accessToken: pair.accessToken, refreshToken: pair.refreshToken });
    },
    signOut() {
      options.tokens.save(null);
    },
    async listPlans() {
      const plans: PlanSummary[] = [];
      let cursor: string | undefined;
      do {
        const page = await authorised<{ plans: PlanSummary[]; nextCursor?: string }>(`/v1/plans${cursor ? `?cursor=${encodeURIComponent(cursor)}` : ""}`, "GET");
        plans.push(...page.plans);
        cursor = page.nextCursor;
      } while (cursor);
      return plans;
    },
    getPlan: (id) => authorised<PlanDetail>(`/v1/plans/${encodeURIComponent(id)}`, "GET"),
    updateSession: (session, body) =>
      authorised<SessionWriteResult>(`/v1/sessions/${encodeURIComponent(session.id)}`, "PATCH", body, { "if-match": `"${session.revision}"` }),
  };
}
