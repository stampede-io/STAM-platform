# Flash-Sale Load Test Report

| Field            | Value              |
|------------------|--------------------|
| Date (UTC)       | YYYY-MM-DD         |
| Commit SHA       | `<sha>`            |
| VUs (peak)       | 1000               |
| Seat pool        | 200                |
| Duration         | 100 s (ramp profile: 20 s → 500 VUs, 30 s → 1000 VUs, 40 s @ 1000 VUs, 10 s → 0) |
| Runner           | k6 vX.Y.Z          |
| Stack            | compose-dev @ `<sha>` |

## Threshold gate (AC1)

| Threshold           | Target      | Observed | Pass |
|---------------------|-------------|----------|------|
| `http_req_failed`   | < 1 %       |          |      |
| `http_req_duration` p99 | < 300 ms  |          |      |
| `oversells`         | == 0        |          |      |

## Latency (all HTTP requests)

| Percentile | Value |
|------------|-------|
| p50        |       |
| p95        |       |
| p99        |       |
| max        |       |

## Latency by step (tag)

| Step             | p50 | p95 | p99 |
|------------------|-----|-----|-----|
| `hold`           |     |     |     |
| `submit_payment` |     |     |     |
| `poll_confirm`   |     |     |     |

## Saga convergence time

Time from `submit-payment` (202 Accepted) to observed `status == CONFIRMED`
(the payment.commands → payment.events → saga completion round-trip):

| Percentile | Value |
|------------|-------|
| p50        |       |
| p95        |       |
| p99        |       |

## Throughput

| Metric                | Value |
|-----------------------|-------|
| Total requests        |       |
| Requests/sec (avg)    |       |
| Holds created         |       |
| Holds conflict (409)  |       |
| Payments submitted    |       |
| Reservations confirmed|       |
| Reservations timed out|       |

## Oversell check

- HTTP-level counter (`oversells` custom metric): **0**
- DB-level verification (partial-unique-index SQL query): **0 oversold seats**

## Notes

- Contention profile: 200 seats vs 1,000 VUs is deliberately extreme.
  Expect a majority of holds to conflict (409) — that is the point.
  What we care about is that no seat is ever held or confirmed twice.
- Any 5xx response is counted as a genuine failure and increments the
  `oversells` counter, tripping the threshold.
