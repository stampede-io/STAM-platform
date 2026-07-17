# Contention Load Test Report

| Field            | Value              |
|------------------|--------------------|
| Date             | YYYY-MM-DD         |
| Commit SHA       | `<sha>`            |
| VU count (peak)  | 300                |
| Seat pool        | 50                 |
| Duration         | 70s (ramp profile) |

## Latency

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
| Reservations created  |       |
| Conflicts (409)       |       |
| Error rate            |       |

## Oversell check

| Check                | Result |
|----------------------|--------|
| k6 `oversells` count | 0      |
| DB query oversells   | 0      |

## What I'd fix next

- (Observations from this run — e.g., tail latency, connection pool tuning, retry storms)
