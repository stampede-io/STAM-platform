import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const rateLimited = new Counter('rate_limited_429s');
const serverErrors = new Counter('server_errors_5xx');
const rateLimitRate = new Rate('rate_limit_rate');
const retryAfterTrend = new Trend('retry_after_header');

const GATEWAY_URL = __ENV.GATEWAY_URL || 'http://localhost:8085';
const AUTH_TOKEN  = __ENV.AUTH_TOKEN  || '';

export const options = {
  scenarios: {
    per_user_burst: {
      executor: 'per-vu-iterations',
      vus: 1,
      iterations: 30,
      exec: 'perUserBurst',
      startTime: '0s',
    },
    per_ip_burst: {
      executor: 'per-vu-iterations',
      vus: 1,
      iterations: 15,
      exec: 'perIpBurst',
      startTime: '5s',
    },
    multi_user_isolation: {
      executor: 'per-vu-iterations',
      vus: 3,
      iterations: 25,
      exec: 'multiUserIsolation',
      startTime: '10s',
    },
  },
  thresholds: {
    'server_errors_5xx': ['count==0'],
    'rate_limited_429s': ['count>0'],
  },
};

export function perUserBurst() {
  const res = http.post(`${GATEWAY_URL}/api/v1/reservations`, null, {
    headers: {
      'Authorization': `Bearer ${AUTH_TOKEN}`,
      'Content-Type': 'application/json',
    },
  });

  const is429 = res.status === 429;
  const is5xx = res.status >= 500;

  if (is429) {
    rateLimited.add(1);

    check(res, {
      'has Retry-After header': (r) => r.headers['Retry-After'] !== undefined,
      'has problem+json content type': (r) =>
        (r.headers['Content-Type'] || '').includes('application/problem+json'),
      'body has status 429': (r) => {
        try { return JSON.parse(r.body).status === 429; } catch { return false; }
      },
    });

    const retryAfter = parseInt(res.headers['Retry-After'], 10);
    if (!isNaN(retryAfter)) {
      retryAfterTrend.add(retryAfter);
    }
  }

  if (is5xx) {
    serverErrors.add(1);
  }

  rateLimitRate.add(is429);

  check(res, {
    'no 5xx errors': (r) => r.status < 500,
    'has X-RateLimit-Limit': (r) => r.headers['X-Ratelimit-Limit'] !== undefined || r.headers['X-RateLimit-Limit'] !== undefined,
  });
}

export function perIpBurst() {
  const res = http.post(`${GATEWAY_URL}/oauth2/token`, null, {
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  });

  const is429 = res.status === 429;
  const is5xx = res.status >= 500;

  if (is429) rateLimited.add(1);
  if (is5xx) serverErrors.add(1);
  rateLimitRate.add(is429);

  check(res, {
    'no 5xx on auth endpoint': (r) => r.status < 500,
  });

  if (is429) {
    check(res, {
      'auth 429 has Retry-After': (r) => r.headers['Retry-After'] !== undefined,
    });
  }
}

export function multiUserIsolation() {
  const vuToken = __ENV[`AUTH_TOKEN_VU${__VU}`] || AUTH_TOKEN || `vu-${__VU}-token`;

  const res = http.post(`${GATEWAY_URL}/api/v1/reservations`, null, {
    headers: {
      'Authorization': `Bearer ${vuToken}`,
      'Content-Type': 'application/json',
    },
    tags: { vu: `${__VU}` },
  });

  const is5xx = res.status >= 500;
  if (is5xx) serverErrors.add(1);
  if (res.status === 429) rateLimited.add(1);

  check(res, {
    'no 5xx in multi-user scenario': (r) => r.status < 500,
  });
}

export function handleSummary(data) {
  const total429s = data.metrics.rate_limited_429s ? data.metrics.rate_limited_429s.values.count : 0;
  const total5xx  = data.metrics.server_errors_5xx ? data.metrics.server_errors_5xx.values.count : 0;

  const summary = `
========================================
  RATE LIMIT BURST TEST RESULTS
========================================
  429 Too Many Requests : ${total429s}
  5xx Server Errors     : ${total5xx}
  Verdict               : ${total5xx === 0 && total429s > 0 ? 'PASS' : 'FAIL'}
========================================
`;

  return {
    stdout: summary,
  };
}
