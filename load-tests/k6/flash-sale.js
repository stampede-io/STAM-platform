// STAM-206 · Flash-sale load test
//
// Exercises the full booking flow end-to-end under peak contention:
//   1. POST /api/v1/reservations        (hold seats)
//   2. POST /api/v1/reservations/{id}/submit-payment  (kick off saga)
//   3. GET  /api/v1/reservations/{id}   (poll until CONFIRMED)
//
// AC1 thresholds:
//   - http_req_failed  < 1 %
//   - http_req_duration p99 < 300 ms
//   - oversells (custom counter) == 0
//
// Companion `verify-oversells.sh` performs the DB-level invariant check
// (SELECT ... HAVING COUNT(*) > 1) after the run.

import http from "k6/http";
import { check, sleep } from "k6";
import { Counter, Rate, Trend } from "k6/metrics";
import { uuidv4 } from "https://jslib.k6.io/k6-utils/1.4.0/index.js";

// ----- Configuration -------------------------------------------------------

const BOOKING_URL = __ENV.BOOKING_URL || "http://localhost:8082";
const CATALOG_URL = __ENV.CATALOG_URL || "http://localhost:8081";
const SHOW_ID = __ENV.SHOW_ID;          // caller must set this; discovered by verify-oversells.sh
const SEAT_IDS_CSV = __ENV.SEAT_IDS;    // comma-separated UUIDs
const CONFIRM_TIMEOUT_MS = parseInt(__ENV.CONFIRM_TIMEOUT_MS || "5000", 10);
const CONFIRM_POLL_MS = parseInt(__ENV.CONFIRM_POLL_MS || "150", 10);

if (!SHOW_ID || !SEAT_IDS_CSV) {
  throw new Error(
    "flash-sale.js requires SHOW_ID and SEAT_IDS env vars — run via run-flash-sale.sh",
  );
}

const SEAT_IDS = SEAT_IDS_CSV.split(",").map((s) => s.trim()).filter(Boolean);

// ----- Custom metrics -------------------------------------------------------

// NOTE: `oversells` here is a *transport-level* counter — it fires when a hold
// request returns a status other than the three valid outcomes (201 created,
// 200 idempotent replay, 409 conflict). It does NOT prove seat oversell —
// that is proven exclusively by the post-run DB invariant check in
// `run-flash-sale.sh` (COUNT(*) HAVING > 1). Under saturation this counter
// counts 5xx too; the DB check is the authoritative signal.
const oversells = new Counter("oversells");
const holdErrors = new Counter("hold_errors_5xx");
const holdsCreated = new Counter("holds_created");
const holdsConflict = new Counter("holds_conflict");
const paymentsSubmitted = new Counter("payments_submitted");
const reservationsConfirmed = new Counter("reservations_confirmed");
const reservationsTimedOut = new Counter("reservations_timed_out");
const sagaConvergenceTime = new Trend("saga_convergence_ms", true);
const flowSuccessRate = new Rate("flow_success");

// ----- k6 options -----------------------------------------------------------

export const options = {
  scenarios: {
    flash_sale: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "20s", target: 500 },   // ramp up
        { duration: "30s", target: 1000 },  // peak - full 1000 VUs
        { duration: "40s", target: 1000 },  // sustain
        { duration: "10s", target: 0 },     // ramp down
      ],
      gracefulRampDown: "10s",
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.01"],           // AC1: < 1% failure
    http_req_duration: ["p(99)<300"],         // AC1: p99 < 300ms
    oversells: ["count==0"],                  // AC1: zero oversells
    "flow_success": ["rate>0.30"],            // 30% of flows must complete end-to-end
                                              // (rest hit expected 409 conflicts on seat contention)
  },
  summaryTrendStats: ["min", "med", "avg", "p(90)", "p(95)", "p(99)", "max"],
};

// ----- Scenario -------------------------------------------------------------

export default function () {
  // Pick a random seat from the pool. Contention is expected and desired.
  const seatId = SEAT_IDS[Math.floor(Math.random() * SEAT_IDS.length)];
  const idempotencyKey = uuidv4();
  const userId = uuidv4();

  // Step 1: hold. Treat 200/201/409 as successful — 409 is the *expected*
  // outcome under contention (the oversell guard rejecting a duplicate hold);
  // counting it as an http failure would guarantee the AC1 threshold miss on
  // a working system.
  const holdRes = http.post(
    `${BOOKING_URL}/api/v1/reservations`,
    JSON.stringify({ showId: SHOW_ID, userId, seatIds: [seatId] }),
    {
      headers: {
        "Content-Type": "application/json",
        "Idempotency-Key": idempotencyKey,
      },
      tags: { step: "hold" },
      responseCallback: http.expectedStatuses(
        { min: 200, max: 201 },
        { min: 409, max: 409 },
      ),
    },
  );

  check(holdRes, {
    "hold status is 201, 200, or 409": (r) =>
      r.status === 201 || r.status === 200 || r.status === 409,
  });

  if (holdRes.status === 409) {
    holdsConflict.add(1);
    flowSuccessRate.add(false);
    return;
  }
  if (holdRes.status >= 500) {
    holdErrors.add(1);
    flowSuccessRate.add(false);
    return;
  }
  if (holdRes.status !== 201 && holdRes.status !== 200) {
    // Anything else (400, unexpected code) is a transport anomaly that the
    // DB-level oversell check must confirm as safe.
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

  // Step 2: submit payment (kicks off saga)
  const submitRes = http.post(
    `${BOOKING_URL}/api/v1/reservations/${reservationId}/submit-payment`,
    null,
    { tags: { step: "submit_payment" } },
  );

  check(submitRes, {
    "submit-payment is 202": (r) => r.status === 202,
  });
  if (submitRes.status !== 202) {
    flowSuccessRate.add(false);
    return;
  }
  paymentsSubmitted.add(1);

  // Step 3: poll until CONFIRMED (saga is async via Kafka)
  const started = Date.now();
  let confirmed = false;
  while (Date.now() - started < CONFIRM_TIMEOUT_MS) {
    sleep(CONFIRM_POLL_MS / 1000);
    const getRes = http.get(
      `${BOOKING_URL}/api/v1/reservations/${reservationId}`,
      { tags: { step: "poll_confirm" } },
    );
    if (getRes.status === 200 && getRes.json("status") === "CONFIRMED") {
      confirmed = true;
      const elapsed = Date.now() - started;
      sagaConvergenceTime.add(elapsed);
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
  console.log(`\n=== Flash-Sale Test Summary ===`);
  console.log(`Show ID:    ${SHOW_ID}`);
  console.log(`Seat pool:  ${SEAT_IDS.length} seats`);
  console.log(`\nRun the following to verify zero oversells in the DB:`);
  console.log(`  bash load-tests/k6/verify-oversells.sh`);
}
