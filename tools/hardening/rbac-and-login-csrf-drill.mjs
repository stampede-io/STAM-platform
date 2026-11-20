// STAM-71 AC1(3) plus one finding from the audit.
//
// RBAC negative: a freshly registered USER's real access token must get 403 on
// catalog writes (ORGANIZER) and on identity's role change (ADMIN), while the
// public catalog read stays open.
//
// Login CSRF probe: replays exactly what a hostile page's auto-submitting
// <form method=POST action=".../login"> would send. It is cross-site, has no
// CSRF token, and carries the attacker's credentials. If identity answers with
// an authenticated session, a victim's browser can be signed in as the
// attacker. The SPA's next authorize then completes as the attacker, and the
// victim's bookings land in the attacker's account.
// usage: node tools/hardening/rbac-and-login-csrf-drill.mjs
import { GATEWAY, register, login } from './pkce-login.mjs';

const email = `rbac-${Date.now()}@stampede.test`;
const password = 'Drill-Password-123';
await register(email, password);
const { accessToken } = await login(email, password);
const auth = { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' };
const role = JSON.parse(Buffer.from(accessToken.split('.')[1], 'base64url')).roles;
console.log(`token for ${email}, roles=${JSON.stringify(role)}`);

const checks = [
  ['GET  /api/v1/venues (public read)', 'GET', '/api/v1/venues', null, (s) => s === 200],
  ['POST /api/v1/venues as USER', 'POST', '/api/v1/venues', { name: 'x', city: 'y' }, (s) => s === 403],
  // identity has no bearer-token chain: a JWT is ignored and the caller is
  // treated as anonymous, so the deny is a 302 to /login, not a 403. Still a
  // deny, recorded in docs/hardening-audit.md as a finding (an ADMIN can't use
  // this endpoint with a JWT either).
  ['PUT  /api/v1/users/{id}/role as USER', 'PUT', '/api/v1/users/00000000-0000-0000-0000-000000000000/role', { role: 'ADMIN' },
    (s, loc) => s === 403 || (s === 302 && loc.endsWith('/login'))],
];
let ok = true;
for (const [label, method, path, body, expect] of checks) {
  const res = await fetch(GATEWAY + path, {
    method, headers: auth, body: body && JSON.stringify(body), redirect: 'manual',
  });
  const loc = res.headers.get('location') ?? '';
  const pass = expect(res.status, loc);
  ok &&= pass;
  console.log(`${pass ? 'OK  ' : 'FAIL'} ${label} -> ${res.status}${loc ? ` ${loc}` : ''}`);
}

const csrf = await fetch(`${GATEWAY}/login`, {
  method: 'POST',
  redirect: 'manual',
  headers: {
    'Content-Type': 'application/x-www-form-urlencoded',
    Origin: 'https://attacker.example',
    Referer: 'https://attacker.example/innocent-page',
  },
  body: new URLSearchParams({ username: email, password }),
});
const session = csrf.headers.getSetCookie().some((c) => c.startsWith('JSESSIONID='));
const loc = csrf.headers.get('location') ?? '';
const accepted = csrf.status === 302 && session && !loc.includes('error');
console.log(`${accepted ? 'FINDING' : 'OK     '} cross-site POST /login with no CSRF token -> ${csrf.status} ${loc}${session ? ' + new session cookie' : ''}`);

process.exit(ok ? 0 : 1);
