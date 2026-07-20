# Sprint 1 Retro — Core + Saga

**Dates:** 2026-07-14 → 2026-07-21
**Goal:** Contention-proof booking core + Kafka/outbox/projection + orchestrated saga with compensation + crash recovery, proven by k6 report showing 0 oversells. Tag v0.1.0.

## Velocity

| Metric              | Planned | Actual | Notes |
|---------------------|---------|--------|-------|
| Story points        | 65      | 65     | All 22 stories (STMP-1 through STMP-22) landed. |
| Stories             | 22      | 22     | Zero carry-over into Sprint 2. |
| Sprint goal met?    | Yes     | Yes    | Zero-oversell invariant proven; v0.1.0 tagged. |

## What went well

- **The oversell guard held.** The partial unique index on `reservation_seats(show_id, seat_id) WHERE status IN ('HELD','CONFIRMED')` (STMP-7) turned out to be the single most valuable line of DDL in the whole sprint. Every subsequent contention test — ContentionIT, ReservationServiceConcurrencyTest, and the k6 flash-sale — shows the invariant holding under adversarial concurrency. Because it lives in the database, it survives every application-level bug I might introduce later.
- **Saga as an explicit state machine paid off immediately.** ADR-0002 chose orchestrated saga over choreography, and every debugging session in Sprint 1 vindicated that call. When a payment came back as `PaymentFailed`, there was one place to look (`BookingSagaOrchestrator.handlePaymentFailed`), not a swarm of consumers reacting to each other. The `saga_instances` table doubled as both durable state and a debugging log.
- **Testcontainers everywhere.** ContentionIT (STMP-11), OutboxIT (STMP-14), SagaRecoveryIT (STMP-21) all run against real Postgres + real Kafka via Testcontainers. Zero mocks at the boundary. The tests are slow (about 90 s of the ~3 min build) but every one of them has caught a real bug at least once.

## What slipped or hurt

- **Setting up transactional outbox took longer than estimated.** STMP-14 was scoped as 3 points; it landed closer to 5. The polling publisher's back-pressure behavior and the `sent_at` vs `attempted_at` distinction were both mis-modeled on the first pass. Lesson: any story that couples "atomic DB write" with "eventually consistent side effect" gets +2 estimation next time.
- **Compose environment drift.** The `.env` file in `compose-dev/` fell out of sync with `.env.example` mid-sprint after STMP-18 (payment service) added new required vars. Only discovered this at Sprint end when trying to run the flash-sale. Action: added a `pre-check` step to `run-flash-sale.sh` that verifies all `.env.example` keys are present.
- **`JAVA_HOME` still points to JDK 17 on the workstation** while `java` on PATH is JDK 21. Every Maven session needs an explicit `export JAVA_HOME=…`. Minor annoyance, not a story, but if this repo grows another contributor it becomes a real friction point. Action next sprint: add `.envrc`/direnv or document in `CONTRIBUTING.md`.
- **`k6` binary not on the workstation.** Ran the load test via the k6 Docker image instead. Fine for CI, less ergonomic for iterative local runs. Sprint 2: add k6 to the tool bootstrap script.

## Surprises

- **Spring Boot 4.1's Kafka listener error handling changed subtly** from 3.x — the DLQ wiring for STMP-16 needed a small config tweak that isn't documented in the older Baeldung articles I was referencing. Bookmarking the actual Spring Kafka reference now, not the tutorials.
- **The saga recovery sweep (STMP-21) was surprisingly simple** once the saga was already an event-sourced entity. It's essentially "find every saga row where `updated_at < now() - stall_threshold` and `state != TERMINAL`, then call the appropriate next-action handler." The hard work was done in STMP-19's state-machine design; the sweep just walked it.

## Metrics from the flash-sale run

Threshold gate:

- `http_req_failed` < 1 %
- `http_req_duration` p99 < 300 ms
- `oversells == 0`

Full numbers: [`load-tests/results/flash-sale-<date>-<sha>.json`](../../load-tests/results/).

## Sprint 2 goal

**"Frontend + Identity, the same demo end-to-end from a browser."**

Concretely: React seat map, PKCE-based OAuth login through `STAM-identity`, gateway routing with a Redis rate-limit filter, and a re-run of the flash-sale scenario going *through* the gateway. Same zero-oversell bar; new latency target `p99 < 500 ms` (gateway adds a hop).

Story-point budget: 55 (deliberately less than Sprint 1's 65 — Sprint 1 slipped on outbox because I over-scoped; keeping some slack for identity's OAuth flow, which I've never written from scratch).

## Retro attendees

- Pulith Thewmika (solo)
