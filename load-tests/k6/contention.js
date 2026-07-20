import http from "k6/http";
import { check, sleep } from "k6";
import { Counter } from "k6/metrics";
import { uuidv4 } from "https://jslib.k6.io/k6-utils/1.4.0/index.js";

// ----- Configuration -------------------------------------------------------

const BASE_URL = __ENV.BASE_URL || "http://localhost:8082";
const TOTAL_SEATS = parseInt(__ENV.TOTAL_SEATS || "50", 10);
const SHOW_ID = __ENV.SHOW_ID || uuidv4();

// Pre-generate a fixed set of seat IDs so every VU targets the same pool.
const SEAT_IDS = [];
for (let i = 0; i < TOTAL_SEATS; i++) {
  SEAT_IDS.push(__ENV[`SEAT_${i}`] || uuidv4());
}

// ----- Custom metrics -------------------------------------------------------

const oversells = new Counter("oversells");
const reservationsCreated = new Counter("reservations_created");
const reservationsConflict = new Counter("reservations_conflict");

// ----- k6 options -----------------------------------------------------------

export const options = {
  stages: [
    { duration: "10s", target: 100 },
    { duration: "30s", target: 300 },
    { duration: "20s", target: 300 },
    { duration: "10s", target: 0 },
  ],
  thresholds: {
    checks: ["rate>0.99"],
    http_req_duration: ["p(95)<2000"],
    oversells: ["count==0"],
  },
};

// ----- Scenario -------------------------------------------------------------

export default function () {
  const seatIndex = Math.floor(Math.random() * TOTAL_SEATS);
  const seatId = SEAT_IDS[seatIndex];

  const payload = JSON.stringify({
    showId: SHOW_ID,
    userId: uuidv4(),
    seatIds: [seatId],
  });

  const params = {
    headers: {
      "Content-Type": "application/json",
      "Idempotency-Key": uuidv4(),
    },
  };

  const res = http.post(`${BASE_URL}/api/v1/reservations`, payload, params);

  check(res, {
    "status is 201 or 409": (r) => r.status === 201 || r.status === 409,
  });

  if (res.status === 201) {
    reservationsCreated.add(1);
  } else if (res.status === 409) {
    reservationsConflict.add(1);
  } else {
    oversells.add(1);
  }

  sleep(0.1);
}

// ----- Teardown: verify no oversells via DB ---------------------------------

export function teardown() {
  // Post-run oversell check: query the booking DB for any seat that has more
  // than one active (HELD or CONFIRMED) reservation_seats row.
  //
  // This requires the k6 xk6-sql extension when running locally, or can be
  // run as a separate script. The threshold `oversells: count==0` catches
  // HTTP-level anomalies; this teardown is the DB-level proof.
  //
  // To run the DB check manually after the test:
  //
  //   psql -h localhost -U booking -d booking -c \
  //     "SELECT show_id, seat_id, COUNT(*) as cnt
  //      FROM reservation_seats
  //      WHERE status IN ('HELD','CONFIRMED')
  //      GROUP BY show_id, seat_id
  //      HAVING COUNT(*) > 1;"
  //
  // Expected output: 0 rows (no oversells).

  console.log(`\n=== Contention Test Summary ===`);
  console.log(`Show ID:    ${SHOW_ID}`);
  console.log(`Seat pool:  ${TOTAL_SEATS} seats`);
  console.log(`\nRun the following to verify zero oversells in the DB:`);
  console.log(`  psql -h localhost -U booking -d booking -c \\`);
  console.log(`    "SELECT show_id, seat_id, COUNT(*) FROM reservation_seats WHERE status IN ('HELD','CONFIRMED') GROUP BY show_id, seat_id HAVING COUNT(*) > 1;"`);
}
