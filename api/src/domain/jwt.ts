// HS256 JSON Web Tokens with Web Crypto, which Workers and Node both provide. Pure: no I/O.

const encoder = new TextEncoder();

function toBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromBase64Url(text: string): Uint8Array | undefined {
  if (!/^[A-Za-z0-9_-]*$/.test(text)) return undefined;
  const padded = text.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(text.length / 4) * 4, "=");
  try {
    return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
  } catch {
    return undefined;
  }
}

const HEADER = toBase64Url(encoder.encode(JSON.stringify({ alg: "HS256", typ: "JWT" })));

function hmacKey(secret: string, usage: "sign" | "verify"): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [usage]);
}

export type JwtPayload = Record<string, unknown> & { sub?: string; scp?: string[]; exp?: number };

export async function signJwt(payload: JwtPayload, secret: string): Promise<string> {
  const body = toBase64Url(encoder.encode(JSON.stringify(payload)));
  const signature = await crypto.subtle.sign("HMAC", await hmacKey(secret, "sign"), encoder.encode(`${HEADER}.${body}`));
  return `${HEADER}.${body}.${toBase64Url(new Uint8Array(signature))}`;
}

/** The payload when the signature matches and the token has not expired; otherwise undefined. */
export async function verifyJwt(token: string, secret: string, nowSec: number): Promise<JwtPayload | undefined> {
  const parts = token.split(".");
  if (parts.length !== 3) return undefined;
  const [header, body, signature] = parts as [string, string, string];
  if (header !== HEADER) return undefined; // only HS256; never `none`
  const given = fromBase64Url(signature);
  if (!given) return undefined;
  const valid = await crypto.subtle.verify("HMAC", await hmacKey(secret, "verify"), given, encoder.encode(`${header}.${body}`));
  if (!valid) return undefined;
  const bytes = fromBase64Url(body);
  if (!bytes) return undefined;
  try {
    const payload = JSON.parse(new TextDecoder().decode(bytes)) as JwtPayload;
    if (typeof payload.exp !== "number" || payload.exp <= nowSec) return undefined;
    return payload;
  } catch {
    return undefined;
  }
}
