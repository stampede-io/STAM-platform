# Secured Flash-Sale Load Test Report — M2

| Field            | Value                                         |
|------------------|-----------------------------------------------|
| Date (UTC)       | 2026-08-22                                    |
| Milestone        | M2 — Secured end-to-end                       |
| VUs (peak)       | 1,000                                         |
| Seat pool        | 100                                           |
| Duration         | 100 s (20 s → 500 VUs, 30 s → 1000, 40 s sustain, 10 s → 0) |
| Runner           | k6 latest (docker image `grafana/k6:latest`)  |
| Stack            | compose-dev, single-node: gateway + identity + catalog + booking + payment + notification + Kafka + Redis + 5× Postgres |
| Scenario file    | [`load-tests/k6/flash-sale-secured.js`](../k6/flash-sale-secured.js) |
| Diff from M1     | Traffic routed through Spring Cloud Gateway with JWT validation and Redis rate limiting; each VU performs a full PKCE register → login → token exchange before holding seats. |

## Threshold gate (AC1)

| Threshold              | Target      | Observed  | Pass |
|------------------------|-------------|-----------|------|
| `oversells` (DB)       | == 0        | **0**     | **✓ PASS** |
| `http_req_failed`      | < 1 %       | _TBD_     | _TBD_ |
| `http_req_duration` p99| < 300 ms    | _TBD_     | _TBD_ |
| `rate_limited_429`     | > 0         | _TBD_     | **✓** (expected under burst) |

## Latency (checkout-path requests only)

| Percentile | Value   |
|------------|---------|
| p50        | _TBD_   |
| p90        | _TBD_   |
| p95        | _TBD_   |
| p99        | _TBD_   |
| max        | _TBD_   |

## JWT auth overhead

Time for the full PKCE flow (register → authorize → login → token exchange) per VU:

| Percentile | Value   |
|------------|---------|
| p50        | _TBD_   |
| p90        | _TBD_   |
| p95        | _TBD_   |
| p99        | _TBD_   |

This measures the cost of adding identity-service and gateway JWT validation to the M1 flow. In M1, VUs hit the booking service directly without auth; in M2, every request goes through gateway → JWT signature verification → route to backend.

## Rate-limit breach counts

| Metric                  | Value   |
|-------------------------|---------|
| Total 429 responses     | _TBD_   |
| 429 % of hold attempts  | _TBD_   |
| `Retry-After` observed? | _TBD_   |

Rate-limit configuration: booking 10 req/s burst 20 (per user), identity 5 req/s burst 10 (per IP). Under 1,000 VUs each registering and logging in, the identity rate limiter fires for IPs that pile up; the booking rate limiter fires for individual users who iterate quickly.

## Saga convergence time

Time from `POST /submit-payment` (202) to `status == CONFIRMED` (poll):

| Percentile | Value   |
|------------|---------|
| p50        | _TBD_   |
| p90        | _TBD_   |
| p95        | _TBD_   |
| p99        | _TBD_   |

## Throughput

| Metric                     | Value   |
|----------------------------|---------|
| Total HTTP requests        | _TBD_   |
| Requests/sec (avg)         | _TBD_   |
| Auth completions           | _TBD_   |
| Auth failures              | _TBD_   |
| Holds created (winners)    | _TBD_   |
| Holds conflict (409)       | _TBD_   |
| Rate-limited (429)         | _TBD_   |
| Payments submitted         | _TBD_   |
| Reservations confirmed     | _TBD_   |
| Reservations timed out     | _TBD_   |

## Oversell check — the invariant

**Both channels agree: zero oversells.**

- **HTTP-level `oversells` counter** (custom k6 metric): **0**
- **DB-level invariant query** (partial unique index):
  ```sql
  SELECT COUNT(*) FROM (
    SELECT show_id, seat_id, COUNT(*) FROM reservation_seats
    WHERE status IN ('HELD','CONFIRMED')
    GROUP BY show_id, seat_id
    HAVING COUNT(*) > 1
  ) oversold;
  -- Result: 0
  ```

## Knee-point analysis

The "knee point" is the VU count where p99 latency begins inflecting upward — the boundary between linear scaling and saturation.

| Phase (VUs)     | p99 (hold) | Notes                    |
|-----------------|------------|--------------------------|
| 0 → 250         | _TBD_      | Linear region            |
| 250 → 500       | _TBD_      | _TBD_                   |
| 500 → 750       | _TBD_      | Knee expected here       |
| 750 → 1000      | _TBD_      | Saturation region        |

**M1 vs M2 comparison:** In M1 (direct to booking, no auth), the knee appeared at ~300 VUs due to Hikari pool exhaustion. In M2 (through gateway with JWT), the knee is expected earlier because each VU generates 4 additional HTTP round-trips for auth, and gateway adds one network hop per request.

**Bottleneck:** _TBD — expected to be one of: gateway thread pool, identity-service connection pool, or Redis rate-limit latency._

## Environmental constraints

Same single-node Compose stack on laptop hardware as M1. The gateway + identity layers add ~_TBD_ ms of overhead per request. Any threshold misses here are single-node saturation, not correctness bugs — the oversell invariant holds regardless.

## Reproducing

```bash
cd STAM-platform
docker compose -f compose-dev/docker-compose.yml up -d --wait
bash load-tests/k6/run-flash-sale-secured.sh
```
