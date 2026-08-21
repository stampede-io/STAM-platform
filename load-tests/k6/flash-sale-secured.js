// STAM-288 · Secured flash-sale load test
//
// setup() builds a pool of authenticated users via the full PKCE flow:
//   1. POST /api/v1/users/register     (register)
//   2. GET  /oauth2/authorize           (PKCE authorize)
//   3. POST /login                      (submit credentials)
//   4. GET  /oauth2/authorize?...       (resume, collect code)
//   5. POST /oauth2/token               (exchange code for JWT)
//
// Each VU then runs the checkout path through the gateway with a pooled JWT:
//   6. POST /api/v1/reservations        (hold seat — Bearer token)
//   7. POST /api/v1/reservations/{id}/submit-payment  (kick off saga)
//   8. GET  /api/v1/reservations/{id}   (poll until CONFIRMED)
//
// Auth runs against identity directly (AUTH_URL) rather than through the
// gateway: the gateway rate-limits the identity route at 5 req/s PER IP, and
// every VU here shares one source IP, so routing pool setup through it would
// 429 the whole pool. Checkout traffic — what this test actually measures —
// still goes through the gateway and its JWT validation on every request.
//
// AC1 thresholds:
//   - http_req_failed  < 1 %   (on expected-status requests)
//   - http_req_duration p99 < 300 ms  (checkout path)
//   - oversells == 0
//   - 429s appear under rate-limit pressure

import http from "k6/http";
import { check, sleep } from "k6";
import { Counter, Rate, Trend } from "k6/metrics";
import { uuidv4 } from "https://jslib.k6.io/k6-utils/1.4.0/index.js";
import { textSummary } from "https://jslib.k6.io/k6-summary/0.0.2/index.js";
import encoding from "k6/encoding";

// ----- Configuration -------------------------------------------------------

const GATEWAY_URL = __ENV.GATEWAY_URL || "http://localhost:8085";
const SHOW_ID = __ENV.SHOW_ID;
const SEAT_IDS_CSV = __ENV.SEAT_IDS;
const CONFIRM_TIMEOUT_MS = parseInt(__ENV.CONFIRM_TIMEOUT_MS || "8000", 10);
const CONFIRM_POLL_MS = parseInt(__ENV.CONFIRM_POLL_MS || "200", 10);
const CLIENT_ID = __ENV.CLIENT_ID || "stampede-spa";
// Must match identity's registered redirect URI (identity.client.redirect-uri).
const REDIRECT_URI = __ENV.REDIRECT_URI || "http://localhost:3000/callback";
const AUTH_URL = __ENV.AUTH_URL || "http://localhost:8084";
const USER_POOL_SIZE = parseInt(__ENV.USER_POOL_SIZE || "200", 10);

if (!SHOW_ID || !SEAT_IDS_CSV) {
  throw new Error(
    "flash-sale-secured.js requires SHOW_ID and SEAT_IDS env vars — run via run-flash-sale-secured.sh",
  );
}

const SEAT_IDS = SEAT_IDS_CSV.split(",").map((s) => s.trim()).filter(Boolean);

// ----- Custom metrics -------------------------------------------------------

const oversells = new Counter("oversells");
const holdErrors5xx = new Counter("hold_errors_5xx");
const holdsCreated = new Counter("holds_created");
const holdsConflict = new Counter("holds_conflict");
const holdUnexpected = new Counter("holds_unexpected_status");
const rateLimited = new Counter("rate_limited_429");
const paymentsSubmitted = new Counter("payments_submitted");
const reservationsConfirmed = new Counter("reservations_confirmed");
const reservationsTimedOut = new Counter("reservations_timed_out");
const authFailures = new Counter("auth_failures");
const sagaConvergenceTime = new Trend("saga_convergence_ms", true);
const jwtOverhead = new Trend("jwt_auth_overhead_ms", true);
const flowSuccessRate = new Rate("flow_success");

// ----- k6 options -----------------------------------------------------------

// CONSTANT_VUS pins the run at a fixed VU count for knee-point sweeps;
// unset, the scenario is the full flash-sale ramp.
const CONSTANT_VUS = parseInt(__ENV.CONSTANT_VUS || "0", 10);
const CONSTANT_DURATION = __ENV.CONSTANT_DURATION || "20s";

export const options = {
  scenarios: {
    flash_sale_secured: CONSTANT_VUS > 0
      ? {
          executor: "constant-vus",
          vus: CONSTANT_VUS,
          duration: CONSTANT_DURATION,
          gracefulStop: "10s",
        }
      : {
          executor: "ramping-vus",
          startVUs: 0,
          stages: [
            { duration: "20s", target: 500 },
            { duration: "30s", target: 1000 },
            { duration: "40s", target: 1000 },
            { duration: "10s", target: 0 },
          ],
          gracefulRampDown: "10s",
        },
  },
  thresholds: {
    http_req_failed: ["rate<0.01"],
    http_req_duration: ["p(99)<300"],
    oversells: ["count==0"],
    "flow_success": ["rate>0.20"],
  },
  summaryTrendStats: ["min", "med", "avg", "p(90)", "p(95)", "p(99)", "max"],
  setupTimeout: "10m",
};

// ----- PKCE helpers ---------------------------------------------------------

function generateCodeVerifier() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return encoding.b64encode(bytes, "rawurl").replace(/=/g, "");
}

async function sha256Base64Url(str) {
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(str));
  return encoding.b64encode(new Uint8Array(hash), "rawurl").replace(/=/g, "");
}

function stripOrigin(url) {
  return url.replace(/^https?:\/\/[^/]+/, "");
}

function jwtClaims(token) {
  return JSON.parse(encoding.b64decode(token.split(".")[1], "rawurl", "s"));
}

// ----- Auth flow (register + PKCE login) ------------------------------------

async function authenticateUser(username, password) {
  const authStart = Date.now();
  // Identity authenticates by email, not by the registration username.
  const loginName = `${username}@loadtest.local`;

  // Pool users are built back-to-back in one VU context. Without clearing the
  // jar, user N+1 inherits user N's authenticated session and /oauth2/authorize
  // short-circuits straight to a code instead of the login form.
  http.cookieJar().clear(AUTH_URL);

  // Step 1: Register
  const regRes = http.post(
    `${AUTH_URL}/api/v1/users/register`,
    JSON.stringify({ username, password, email: loginName }),
    {
      headers: { "Content-Type": "application/json" },
      tags: { step: "register" },
      redirects: 0,
    },
  );

  // 201 = new user, 409 = already exists (both OK for load test)
  if (regRes.status !== 201 && regRes.status !== 409) {
    authFailures.add(1);
    return null;
  }

  // Step 2: PKCE authorize
  const codeVerifier = generateCodeVerifier();
  const codeChallenge = await sha256Base64Url(codeVerifier);
  const state = uuidv4();
  const redirectUri = REDIRECT_URI;

  const authorizeRes = http.get(
    `${AUTH_URL}/oauth2/authorize?` +
      `response_type=code&client_id=${CLIENT_ID}` +
      `&redirect_uri=${encodeURIComponent(redirectUri)}` +
      `&scope=openid&state=${state}` +
      `&code_challenge=${codeChallenge}&code_challenge_method=S256`,
    { tags: { step: "authorize" }, redirects: 0 },
  );

  // Should redirect to /login
  if (authorizeRes.status !== 302 && authorizeRes.status !== 200) {
    authFailures.add(1);
    return null;
  }

  // Step 3: Submit login form. On success this redirects back to the saved
  // /oauth2/authorize request rather than straight to the redirect_uri.
  const loginRes = http.post(
    `${AUTH_URL}/login`,
    { username: loginName, password },
    {
      tags: { step: "login" },
      redirects: 0,
    },
  );

  if (loginRes.status !== 302) {
    authFailures.add(1);
    return null;
  }

  const resumeLocation = loginRes.headers["Location"] || "";
  if (resumeLocation.includes("/login?error") || !resumeLocation.includes("/oauth2/authorize")) {
    authFailures.add(1);
    return null;
  }

  // Step 4: Resume the authorize request to collect the code. Identity builds
  // absolute Locations from its own in-cluster host, so re-point at the gateway.
  const resumeRes = http.get(`${AUTH_URL}${stripOrigin(resumeLocation)}`, {
    tags: { step: "authorize_resume" },
    redirects: 0,
  });

  if (resumeRes.status !== 302) {
    authFailures.add(1);
    return null;
  }

  const codeMatch = (resumeRes.headers["Location"] || "").match(/[?&]code=([^&]+)/);
  if (!codeMatch) {
    authFailures.add(1);
    return null;
  }
  const authorizationCode = codeMatch[1];

  // Step 4: Exchange code for token
  const tokenRes = http.post(
    `${AUTH_URL}/oauth2/token`,
    `grant_type=authorization_code&code=${authorizationCode}` +
      `&redirect_uri=${encodeURIComponent(redirectUri)}` +
      `&client_id=${CLIENT_ID}` +
      `&code_verifier=${codeVerifier}`,
    {
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      tags: { step: "token" },
    },
  );

  if (tokenRes.status !== 200) {
    authFailures.add(1);
    return null;
  }

  const accessToken = tokenRes.json("access_token");
  if (!accessToken) {
    authFailures.add(1);
    return null;
  }

  const userId = jwtClaims(accessToken).user_id;
  if (!userId) {
    authFailures.add(1);
    return null;
  }

  jwtOverhead.add(Date.now() - authStart);
  return { accessToken, userId };
}

// ----- Setup: build the authenticated user pool ------------------------------

export async function setup() {
  const sessions = [];
  for (let i = 0; i < USER_POOL_SIZE; i++) {
    const session = await authenticateUser(
      `k6user_${uuidv4().substring(0, 8)}`,
      "LoadTest1!",
    );
    if (session) {
      sessions.push(session);
    }
  }

  if (sessions.length === 0) {
    throw new Error(`auth pool is empty — could not authenticate against ${AUTH_URL}`);
  }
  console.log(`Auth pool ready: ${sessions.length}/${USER_POOL_SIZE} users`);
  return { sessions };
}

// ----- Scenario -------------------------------------------------------------

export default function (data) {
  const session = data.sessions[Math.floor(Math.random() * data.sessions.length)];

  const authHeaders = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${session.accessToken}`,
  };

  // Pick a random seat
  const seatId = SEAT_IDS[Math.floor(Math.random() * SEAT_IDS.length)];
  const idempotencyKey = uuidv4();

  // Step 5: Hold seat (through gateway with JWT)
  const holdRes = http.post(
    `${GATEWAY_URL}/api/v1/reservations`,
    JSON.stringify({ showId: SHOW_ID, userId: session.userId, seatIds: [seatId] }),
    {
      headers: { ...authHeaders, "Idempotency-Key": idempotencyKey },
      tags: { step: "hold" },
      responseCallback: http.expectedStatuses(
        { min: 200, max: 201 },
        { min: 409, max: 409 },
        { min: 429, max: 429 },
      ),
    },
  );

  check(holdRes, {
    "hold status is 201, 200, 409, or 429": (r) =>
      [200, 201, 409, 429].includes(r.status),
  });

  if (holdRes.status === 429) {
    rateLimited.add(1);
    flowSuccessRate.add(false);
    return;
  }
  if (holdRes.status === 409) {
    holdsConflict.add(1);
    flowSuccessRate.add(false);
    return;
  }
  if (holdRes.status >= 500) {
    holdErrors5xx.add(1);
    flowSuccessRate.add(false);
    return;
  }
  if (holdRes.status !== 201 && holdRes.status !== 200) {
    holdUnexpected.add(1);
    flowSuccessRate.add(false);
    return;
  }

  holdsCreated.add(1);
  const reservationId = holdRes.json("reservationId");
  if (!reservationId) {
    flowSuccessRate.add(false);
    return;
  }

  // Step 6: Submit payment (through gateway with JWT)
  const submitRes = http.post(
    `${GATEWAY_URL}/api/v1/reservations/${reservationId}/submit-payment`,
    null,
    {
      headers: authHeaders,
      tags: { step: "submit_payment" },
    },
  );

  check(submitRes, {
    "submit-payment is 202": (r) => r.status === 202,
  });
  if (submitRes.status !== 202) {
    flowSuccessRate.add(false);
    return;
  }
  paymentsSubmitted.add(1);

  // Step 7: Poll until CONFIRMED
  const started = Date.now();
  let confirmed = false;
  while (Date.now() - started < CONFIRM_TIMEOUT_MS) {
    sleep(CONFIRM_POLL_MS / 1000);
    const getRes = http.get(
      `${GATEWAY_URL}/api/v1/reservations/${reservationId}`,
      {
        headers: authHeaders,
        tags: { step: "poll_confirm" },
      },
    );
    if (getRes.status === 200 && getRes.json("status") === "CONFIRMED") {
      confirmed = true;
      sagaConvergenceTime.add(Date.now() - started);
      break;
    }
  }

  if (confirmed) {
    reservationsConfirmed.add(1);
    flowSuccessRate.add(true);
  } else {
    reservationsTimedOut.add(1);
    flowSuccessRate.add(false);
  }
}

// ----- Teardown ------------------------------------------------------------

export function teardown(data) {
  console.log(`\n=== Secured Flash-Sale Test Summary ===`);
  console.log(`Gateway:    ${GATEWAY_URL}`);
  console.log(`Auth:       ${AUTH_URL}`);
  console.log(`Show ID:    ${SHOW_ID}`);
  console.log(`Seat pool:  ${SEAT_IDS.length} seats`);
  console.log(`User pool:  ${data.sessions.length} authenticated users`);
}

// ----- Summary --------------------------------------------------------------

// k6's built-in --summary-export serialises setup_data, which here holds live
// access tokens for every pooled user. Emit the summary ourselves so the
// committed artifact carries metrics only and never a bearer token.
export function handleSummary(data) {
  const { setup_data, ...safe } = data;
  const out = { stdout: textSummary(data) };
  if (__ENV.SUMMARY_JSON) {
    out[__ENV.SUMMARY_JSON] = JSON.stringify(safe, null, 2);
  }
  return out;
}
