// STAM-288 · Secured flash-sale load test
//
// Full journey through the gateway with JWT auth:
//   1. POST /api/v1/users/register     (register)
//   2. GET  /oauth2/authorize           (PKCE authorize)
//   3. POST /login                      (submit credentials)
//   4. POST /oauth2/token               (exchange code for JWT)
//   5. POST /api/v1/reservations        (hold seat — Bearer token)
//   6. POST /api/v1/reservations/{id}/submit-payment  (kick off saga)
//   7. GET  /api/v1/reservations/{id}   (poll until CONFIRMED)
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
import encoding from "k6/encoding";
import { crypto } from "k6/experimental/webcrypto";

// ----- Configuration -------------------------------------------------------

const GATEWAY_URL = __ENV.GATEWAY_URL || "http://localhost:8085";
const SHOW_ID = __ENV.SHOW_ID;
const SEAT_IDS_CSV = __ENV.SEAT_IDS;
const CONFIRM_TIMEOUT_MS = parseInt(__ENV.CONFIRM_TIMEOUT_MS || "8000", 10);
const CONFIRM_POLL_MS = parseInt(__ENV.CONFIRM_POLL_MS || "200", 10);
const CLIENT_ID = __ENV.CLIENT_ID || "stampede-spa";

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
const rateLimited = new Counter("rate_limited_429");
const paymentsSubmitted = new Counter("payments_submitted");
const reservationsConfirmed = new Counter("reservations_confirmed");
const reservationsTimedOut = new Counter("reservations_timed_out");
const authFailures = new Counter("auth_failures");
const sagaConvergenceTime = new Trend("saga_convergence_ms", true);
const jwtOverhead = new Trend("jwt_auth_overhead_ms", true);
const flowSuccessRate = new Rate("flow_success");

// ----- k6 options -----------------------------------------------------------

export const options = {
  scenarios: {
    flash_sale_secured: {
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
};

// ----- PKCE helpers ---------------------------------------------------------

function generateCodeVerifier() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return encoding.b64encode(bytes, "rawurl").replace(/=/g, "");
}

function sha256Base64Url(str) {
  const hash = crypto.subtle.digestSync("SHA-256", new TextEncoder().encode(str));
  return encoding.b64encode(new Uint8Array(hash), "rawurl").replace(/=/g, "");
}

// ----- Auth flow (register + PKCE login) ------------------------------------

function authenticateUser(username, password) {
  const authStart = Date.now();

  // Step 1: Register
  const regRes = http.post(
    `${GATEWAY_URL}/api/v1/users/register`,
    JSON.stringify({ username, password, email: `${username}@loadtest.local` }),
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
  const codeChallenge = sha256Base64Url(codeVerifier);
  const state = uuidv4();
  const redirectUri = `${GATEWAY_URL}/callback`;

  const authorizeRes = http.get(
    `${GATEWAY_URL}/oauth2/authorize?` +
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

  // Step 3: Submit login form
  const loginRes = http.post(
    `${GATEWAY_URL}/login`,
    { username, password },
    {
      tags: { step: "login" },
      redirects: 0,
    },
  );

  // Should redirect back with ?code=...
  if (loginRes.status !== 302) {
    authFailures.add(1);
    return null;
  }

  const locationHeader = loginRes.headers["Location"] || "";
  const codeMatch = locationHeader.match(/[?&]code=([^&]+)/);
  if (!codeMatch) {
    authFailures.add(1);
    return null;
  }
  const authorizationCode = codeMatch[1];

  // Step 4: Exchange code for token
  const tokenRes = http.post(
    `${GATEWAY_URL}/oauth2/token`,
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

  jwtOverhead.add(Date.now() - authStart);
  return accessToken;
}

// ----- Scenario -------------------------------------------------------------

export default function () {
  const vuId = `vu-${__VU}-${__ITER}`;
  const username = `k6user_${uuidv4().substring(0, 8)}`;
  const password = "LoadTest1!";

  // Authenticate through gateway
  const token = authenticateUser(username, password);
  if (!token) {
    flowSuccessRate.add(false);
    return;
  }

  const authHeaders = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${token}`,
  };

  // Pick a random seat
  const seatId = SEAT_IDS[Math.floor(Math.random() * SEAT_IDS.length)];
  const idempotencyKey = uuidv4();

  // Step 5: Hold seat (through gateway with JWT)
  const holdRes = http.post(
    `${GATEWAY_URL}/api/v1/reservations`,
    JSON.stringify({ showId: SHOW_ID, seatIds: [seatId] }),
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
    oversells.add(1);
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

export function teardown() {
  console.log(`\n=== Secured Flash-Sale Test Summary ===`);
  console.log(`Gateway:    ${GATEWAY_URL}`);
  console.log(`Show ID:    ${SHOW_ID}`);
  console.log(`Seat pool:  ${SEAT_IDS.length} seats`);
  console.log(`\nRun the following to verify zero oversells in the DB:`);
  console.log(`  bash load-tests/k6/verify-oversells.sh`);
}
