# ADR-0003: Kafka over RabbitMQ and SQS

**Status:** Accepted
**Date:** 2026-07-15
**Author:** Pulith Thewmika

## Context

We need an asynchronous messaging backbone for Stampede. It carries saga commands and responses (ADR-0002), domain events for building read-model projections, and general integration events between services. The three candidates we evaluated are Apache Kafka, RabbitMQ, and Amazon SQS.

**RabbitMQ** is a message broker. It routes messages from producers to consumer queues using exchanges and bindings. It is excellent at what it does: flexible routing (topic, fanout, headers), per-message acknowledgment, dead-letter queues, and priority queues. But it is fundamentally a *message broker* — once a consumer acknowledges a message, the broker deletes it. If I deploy a new projection service tomorrow that needs to rebuild its read model from historical events, those events are gone. I would have to re-publish them from the source service's database, which defeats the purpose of event-driven architecture. RabbitMQ also does not guarantee ordering within a queue under all conditions (redeliveries can reorder), which matters when we need to process booking events for the same seat in sequence.

**Amazon SQS** shares the same fundamental trait: it is a message queue that deletes messages after consumption. SQS FIFO queues offer ordering within a message group, which maps reasonably to our partitioning needs. But SQS FIFO has a throughput cap of 300 messages/second per message group (3,000 with batching), and more critically, it still deletes consumed messages. Like RabbitMQ, it is the wrong primitive for a system that needs event replay. SQS also ties us to AWS, which conflicts with our goal of running locally with Docker Compose and deploying to any Kubernetes cluster.

**Apache Kafka** is not a message broker — it is a distributed, append-only, replayable commit log. Producers append records to topic partitions. Consumers read from an offset and advance their own cursor. The log retains records according to a configurable retention policy, not consumption status. This distinction has concrete consequences for us:

- **Rebuildable projections.** If we deploy a new read-model service, or discover a bug in an existing projection, we reset the consumer group offset to zero and replay the entire event history. The catalog service's search index, the analytics service's dashboards, and the booking service's denormalized views are all rebuildable from the Kafka log without touching the source service.
- **Per-partition ordering.** Kafka guarantees strict ordering within a partition. By keying booking events on `eventId` or `seatId`, we ensure that all events for the same entity are processed in order by a single consumer. This is critical for the saga orchestrator — we cannot have a `PaymentCompleted` event processed before the `SeatReserved` event for the same booking.
- **Consumer independence.** Multiple consumer groups can read the same topic at their own pace. The saga orchestrator, the projection builder, and the notification service all consume from `booking-events` independently. Adding a new consumer does not require reconfiguring the broker or the producer.

A queue deletes on consume — that is the wrong primitive for event sourcing and CQRS. We need a log that retains events and lets any consumer replay from any point.

## Decision

We will use Apache Kafka as the messaging backbone for all inter-service communication. Topic partitioning will be keyed on the entity ID that requires ordering (e.g., `eventId` for event lifecycle, `bookingId` for saga coordination). We will use the transactional outbox pattern (polling or CDC) to publish events atomically with database writes, ensuring no events are lost or duplicated even if the service crashes between committing to the database and publishing to Kafka.

## Consequences

**Positive:**
- Events are retained and replayable. Projections can be rebuilt from scratch without coordinating with source services.
- Strict per-partition ordering eliminates race conditions in saga processing and projection building.
- Multiple consumer groups read independently — adding a new consumer is a deployment, not a reconfiguration.
- Kafka's throughput (millions of messages/second with proper partitioning) is well beyond our needs, giving us headroom for traffic spikes during flash sales.

**Negative:**
- Kafka is operationally heavier than RabbitMQ or SQS. A minimum deployment requires ZooKeeper (or KRaft) and at least 3 brokers for fault tolerance. For local development, we will use a single-broker Docker Compose setup, but production requires meaningful cluster management.
- Kafka's consumer model (poll-based, offset management, rebalancing) has a steeper learning curve than RabbitMQ's push model or SQS's simple receive-delete API.
- Kafka does not natively support delayed/scheduled messages or priority queues. If we need "retry this message in 5 minutes," we must implement it ourselves with a retry topic and timestamp-based filtering.
- Message ordering is per-partition, not per-topic. Choosing the wrong partition key can either create hot partitions (all traffic on one partition) or break ordering guarantees. Key selection requires careful thought per topic.

We accept these costs because replayability and ordering are non-negotiable for our event-sourcing and saga patterns, and because Kafka's operational complexity is manageable with Docker Compose locally and Helm charts in production.
