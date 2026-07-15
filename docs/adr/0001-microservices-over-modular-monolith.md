# ADR-0001: Microservices over Modular Monolith

**Status:** Accepted
**Date:** 2026-07-15
**Author:** Pulith Thewmika

## Context

We need to choose a deployment architecture for Stampede, a high-concurrency event ticketing platform. The two realistic options are a modular monolith and a microservices architecture.

The modular monolith is genuinely attractive. A single deployable unit means one build pipeline, one deployment artifact, and no network boundaries to reason about. In-process method calls between modules are orders of magnitude faster than HTTP or messaging. Transaction management is trivial — a single database transaction can span multiple modules atomically. Refactoring across module boundaries is a rename, not a contract migration. For a small team shipping fast, this is often the right call, and many systems that claim to need microservices would be better served by a well-structured monolith.

However, several specific forces tip the balance toward microservices for this system:

**Blast-radius isolation.** When 50,000 users hit "Buy" simultaneously for a concert drop, the booking path — seat locking, payment orchestration, ticket issuance — is the hottest code in the system. If a bug in the notification renderer or a slow catalog query causes memory pressure or thread-pool exhaustion, it takes down the entire monolith, including the checkout flow. With microservices, a crash in `STAM-notification` does not touch `STAM-booking`. Users complete their purchase; they just get their confirmation email late.

**Independent scaling of browse vs checkout.** The catalog-browsing path (searching events, viewing seat maps) has a read-heavy, cacheable traffic pattern. The checkout path is write-heavy, contention-sensitive, and bursty. In a monolith, we scale the entire process to handle the checkout burst, which means over-provisioning the catalog code by 10x. With separate services, we can run 2 catalog replicas behind a CDN while spinning up 12 booking instances during a flash sale, then scaling them back down.

**Per-service data ownership.** The booking service needs a database optimized for row-level locking and serializable isolation (Postgres with `SELECT ... FOR UPDATE SKIP LOCKED`). The catalog service benefits from read replicas and eventually-consistent caches. A monolith sharing a single database makes it very hard to tune these independently, and a shared schema couples teams to each other's migration schedules.

**Honesty about learning objectives.** This is a portfolio project. One of its explicit goals is to demonstrate production-grade distributed systems practices — saga orchestration, event-driven projections, independent CI/CD, observability across service boundaries. A monolith, no matter how well-structured, does not exercise these skills.

## Decision

We will build Stampede as a microservices architecture with the following services: `STAM-gateway`, `STAM-catalog`, `STAM-booking`, `STAM-payment`, `STAM-notification`, `STAM-identity`, and `STAM-frontend`. Each service owns its own database and communicates asynchronously via events, with synchronous calls only at the edge (gateway to service).

## Consequences

**Positive:**
- A failure in one service does not cascade to unrelated flows.
- Each service scales independently based on its actual traffic pattern.
- Teams (or a solo developer working on one service at a time) can deploy independently without coordinating database migrations.
- The project demonstrates real distributed systems engineering.

**Negative:**
- Distributed transactions are hard. We cannot rely on database-level atomicity across services and must implement saga patterns (see ADR-0002).
- Operational complexity increases significantly: we need container orchestration, service discovery, distributed tracing, centralized logging, and health checks that a monolith gets for free.
- Network calls introduce latency and failure modes that in-process calls do not. We need circuit breakers, retries with backoff, and timeout budgets.
- Local development requires running multiple services, which means Docker Compose at minimum.
- Debugging a request that spans 4 services is harder than stepping through a single process.

We accept these costs because the isolation and scaling benefits are load-bearing for a ticketing platform, and because the operational complexity is itself a learning objective.
