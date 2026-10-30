import type { Context } from "hono";

/** RFC 9457 Problem Details, as `application/problem+json`. */
export function problem(
  c: Context,
  status: 400 | 401 | 403 | 404 | 409 | 413 | 422 | 429 | 500,
  type: string,
  title: string,
  headers: Record<string, string> = {},
  extra: Record<string, unknown> = {},
): Response {
  return new Response(JSON.stringify({ type, title, status, ...extra }), {
    status,
    headers: { "content-type": "application/problem+json", ...headers },
  });
}
