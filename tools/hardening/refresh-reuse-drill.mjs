// STAM-71 AC1(2): refresh-token reuse drill against the running stack.
// Logs in for real, rotates the refresh token once, then replays the OLD one,
// the way a thief holding a stolen cookie would. Expected (CLAUDE.md §16,
// FamilyAwareAuthorizationService): the replay is rejected AND the whole
// family is revoked, so the legitimate NEW token stops working too.
// usage: node tools/hardening/refresh-reuse-drill.mjs   (exit 0 = drill passed)
import { register, login, refresh } from './pkce-login.mjs';

const tag = (s) => (s ? `${s.slice(0, 12)}…` : '(none)');
const email = `drill-${Date.now()}@stampede.test`;
const password = 'Drill-Password-123';

await register(email, password);
const { refreshCookie: rt1 } = await login(email, password);
console.log(`1. PKCE login            -> refresh token RT1 ${tag(rt1)}`);

const r1 = await refresh(rt1);
console.log(`2. refresh with RT1      -> ${r1.status}, rotated to RT2 ${tag(r1.nextCookie)}`);

const r2 = await refresh(rt1);
console.log(`3. REPLAY RT1 (stolen)   -> ${r2.status}${r2.nextCookie === '' ? ', cookie cleared' : ''}`);

const r3 = await refresh(r1.nextCookie);
console.log(`4. legit RT2 after replay -> ${r3.status} (family revoked if 401)`);

const pass = r1.status === 200 && r1.nextCookie && r1.nextCookie !== rt1
  && r2.status === 401 && r3.status === 401;
console.log(pass ? 'PASS: reuse detected, family revoked' : 'FAIL');
process.exit(pass ? 0 : 1);
