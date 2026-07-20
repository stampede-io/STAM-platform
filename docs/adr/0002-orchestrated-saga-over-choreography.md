# ADR-0002: Orchestrated Saga over Choreography

**Status:** Accepted
**Date:** 2026-07-15
**Author:** Pulith Thewmika

## Context

Since we chose microservices (ADR-0001), we no longer have the luxury of a single ACID transaction spanning "reserve seat + charge payment + issue ticket." We need a distributed transaction pattern. The three realistic options are:

1. **Two-phase commit (2PC):** A coordinator asks all participants to prepare, then tells them to commit. This gives us atomicity but requires all participants to hold locks during the prepare phase. It is blocking — if the coordinator crashes between prepare and commit, every participant is stuck holding locks until it recovers. In a high-concurrency ticketing system where seat locks are the scarcest resource, blocking participants for the duration of a coordinator recovery is not acceptable. 2PC also requires all participants to support the XA protocol, which rules out most message brokers and many cloud-managed databases. We ruled this out early.

2. **Choreography (event-driven):** Each service reacts to events from other services. Booking emits `SeatReserved`, Payment hears it and charges the card, then emits `PaymentCompleted`, Notification hears that and sends the email. No central coordinator. This is elegant for simple, linear flows. But our booking flow is not simple: if payment fails, we need to release the seat; if ticket issuance fails after payment succeeds, we need to refund the payment *and* release the seat. With choreography, compensation logic is scattered across every service that participates. To understand the full saga, I have to mentally reconstruct it from event handlers spread across 4 codebases. When a new failure mode appears, I have to figure out which services need a new event handler and hope I don't miss one. Debugging a stuck booking means grepping Kafka topics across services to piece together what happened. Choreography works well when services are truly independent — "user signed up, send welcome email" — but our booking flow has strong sequential dependencies and branching compensation paths.

3. **Orchestration:** A single saga orchestrator (living in the booking service) holds the state machine for the entire booking flow. It tells Payment "charge this card," waits for the response, then tells Notification "send confirmation," and so on. If any step fails, the orchestrator knows exactly where it failed and runs compensation steps in reverse order from a single place.

## Decision

We will use an orchestrated saga pattern for the booking flow. The orchestrator will live in `STAM-booking` as a state machine persisted in a `saga_instances` table. Each saga instance records its current step, the data collected so far, and a timestamp for timeout detection.

The orchestrator communicates with participant services via Kafka commands and events. It sends a command (e.g., `ProcessPayment`), waits for a response event (e.g., `PaymentProcessed` or `PaymentFailed`), and transitions the state machine accordingly.

Compensation is defined in one place: the orchestrator's state machine definition lists both the forward action and the compensating action for each step. If step 3 fails, the orchestrator walks backward through steps 2 and 1, calling their compensating actions.

## Consequences

**Positive:**
- The entire saga flow is readable in one file — the state machine definition. A new developer can understand the booking flow without jumping across services.
- `saga_instances` is a queryable table. "Show me all bookings stuck in `PAYMENT_PENDING` for more than 5 minutes" is a SQL query, not a Kafka topic archaeology expedition.
- Compensation logic lives next to the forward logic. When we add a new step (e.g., loyalty points), the compensating action goes in the same place.
- Crash recovery is straightforward: on startup, the orchestrator queries for saga instances that have been in a non-terminal state beyond their timeout and resumes or compensates them.

**Negative:**
- The orchestrator is a coordination bottleneck and a single point of coupling. Every participant service must understand the commands the orchestrator sends. Adding a new step means changing the orchestrator, not just deploying a new service.
- The booking service becomes "heavier" than a pure domain service because it carries orchestration responsibilities.
- Orchestration can become a crutch — if we are not disciplined, we might route unrelated flows through the orchestrator instead of using simple event-driven patterns where they fit.

**When choreography would win:** For flows where services are genuinely independent and there is no meaningful compensation (e.g., "event created -> update search index, notify subscribers, generate thumbnail"), choreography is simpler and avoids the coupling overhead. We will use choreography for these fire-and-forget projection flows alongside orchestration for the booking saga.
