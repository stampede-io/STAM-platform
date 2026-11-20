// STAM-71: a real OAuth 2.1 Authorization Code + PKCE (S256) login through
// the gateway, over plain HTTP, with no browser and nothing mocked:
//   /oauth2/authorize -> identity's /login form (CSRF) -> code -> gateway BFF
//   /api/v1/oauth2/token, which returns the access token and sets the refresh
//   token as the httpOnly `stampede_rt` cookie (ADR-0005).
// Exported for the drills in this folder. Node 20+, no dependencies.
import crypto from 'node:crypto';

export const GATEWAY = process.env.GATEWAY_URL ?? 'http://localhost:8085';
const CLIENT_ID = 'stampede-spa';
const REDIRECT_URI = process.env.REDIRECT_URI ?? 'http://localhost:5173/auth/callback';
const SCOPE = 'openid profile email offline_access';

const b64url = (buf) => buf.toString('base64url');

// Minimal cookie jar: name -> value, across every host:port on localhost.
function jar() {
  const cookies = new Map();
  return {
    store(res) {
      for (const c of res.headers.getSetCookie()) {
        const [pair] = c.split(';');
        const i = pair.indexOf('=');
        cookies.set(pair.slice(0, i), pair.slice(i + 1));
      }
    },
    header() {
      return [...cookies].map(([k, v]) => `${k}=${v}`).join('; ');
    },
    get: (name) => cookies.get(name),
  };
}

export async function register(email, password) {
  const res = await fetch(`${GATEWAY}/api/v1/users/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  if (![200, 201, 409].includes(res.status)) throw new Error(`register ${res.status}`);
}

/** Returns { accessToken, refreshCookie } for a fresh login. */
export async function login(email, password) {
  const cookies = jar();
  const verifier = b64url(crypto.randomBytes(32));
  const challenge = b64url(crypto.createHash('sha256').update(verifier).digest());
  const state = b64url(crypto.randomBytes(16));

  const go = async (url, init = {}) => {
    const res = await fetch(new URL(url, GATEWAY), {
      ...init,
      redirect: 'manual',
      headers: { ...(init.headers ?? {}), Cookie: cookies.header() },
    });
    cookies.store(res);
    return res;
  };

  const authorize = `/oauth2/authorize?${new URLSearchParams({
    response_type: 'code', client_id: CLIENT_ID, redirect_uri: REDIRECT_URI,
    scope: SCOPE, state, code_challenge: challenge, code_challenge_method: 'S256',
  })}`;

  let res = await go(authorize); // -> 302 /login
  const loginPage = await go('/login');
  const html = await loginPage.text();
  // Sent when the form carries one. Today it doesn't: identity disables CSRF
  // (see docs/hardening-audit.md, finding on login CSRF).
  const csrf = html.match(/name="_csrf"[^>]*value="([^"]+)"/)?.[1];
  const form = { username: email, password };
  if (csrf) form._csrf = csrf;

  res = await go('/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(form),
  });
  // Follow the post-login redirects until identity hands back the code.
  for (let hop = 0; hop < 5; hop++) {
    const loc = res.headers.get('location');
    if (!loc) throw new Error(`login stopped at ${res.status} with no redirect`);
    if (loc.startsWith(REDIRECT_URI)) {
      const params = new URL(loc).searchParams;
      if (params.get('state') !== state) throw new Error('state mismatch');
      const code = params.get('code');
      const token = await fetch(`${GATEWAY}/api/v1/oauth2/token`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          grant_type: 'authorization_code', code, redirect_uri: REDIRECT_URI,
          client_id: CLIENT_ID, code_verifier: verifier,
        }),
      });
      cookies.store(token);
      const body = await token.json();
      if (!token.ok) throw new Error(`token exchange ${token.status} ${JSON.stringify(body)}`);
      return { accessToken: body.access_token, refreshCookie: cookies.get('stampede_rt'), body };
    }
    res = await go(loc);
  }
  throw new Error('too many redirects');
}

/** POST /api/v1/oauth2/refresh with a given refresh cookie value. */
export async function refresh(refreshCookie) {
  const res = await fetch(`${GATEWAY}/api/v1/oauth2/refresh`, {
    method: 'POST',
    headers: { Cookie: `stampede_rt=${refreshCookie}` },
  });
  const next = res.headers.getSetCookie()
    .map((c) => c.split(';')[0])
    .find((c) => c.startsWith('stampede_rt='))?.slice('stampede_rt='.length);
  let body = null;
  try { body = await res.json(); } catch { /* empty body */ }
  return { status: res.status, nextCookie: next, body };
}
