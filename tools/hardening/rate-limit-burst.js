// STAM-71 AC1(4): k6 burst against the gateway's Redis token buckets
// (booking: 10 req/s burst 20 per user; identity: 5 req/s burst 10 per IP).
// Each scenario fires 60 requests in about one second, well past the burst,
// and the thresholds require both 429s and allowed requests. A limiter that
// never fires fails the run, and so does one that blocks everything.
//
// usage (TOKEN = a real USER access token, e.g. from pkce-login.mjs):
//   k6 run -e TOKEN=... tools/hardening/rate-limit-burst.js
import http from 'k6/http';
import { Counter } from 'k6/metrics';

const BASE = __ENV.GATEWAY_URL || 'http://localhost:8085';
const limited = new Counter('rate_limited_429');
const allowed = new Counter('allowed_non_429');

export const options = {
  scenarios: {
    booking_per_user: {
      executor: 'shared-iterations', vus: 20, iterations: 60, maxDuration: '10s',
      exec: 'booking', tags: { limiter: 'booking' },
    },
    identity_per_ip: {
      executor: 'shared-iterations', vus: 20, iterations: 60, maxDuration: '10s',
      exec: 'identity', tags: { limiter: 'identity' }, startTime: '3s',
    },
  },
  thresholds: {
    'rate_limited_429{limiter:booking}': ['count>0'],
    'allowed_non_429{limiter:booking}': ['count>=10'],
    'rate_limited_429{limiter:identity}': ['count>0'],
    'allowed_non_429{limiter:identity}': ['count>=5'],
  },
};

function record(res) {
  if (res.status === 429) limited.add(1);
  else allowed.add(1);
}

export function booking() {
  record(http.get(`${BASE}/api/v1/reservations/00000000-0000-0000-0000-000000000000`, {
    headers: { Authorization: `Bearer ${__ENV.TOKEN}` },
  }));
}

export function identity() {
  record(http.get(`${BASE}/login`, { redirects: 0 }));
}
