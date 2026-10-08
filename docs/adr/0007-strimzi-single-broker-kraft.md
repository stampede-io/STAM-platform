# ADR-0007: Strimzi Operator, Single-Broker KRaft Kafka

**Status:** Accepted
**Date:** 2026-10-07
**Author:** Pulith Thewmika

## Context

compose-dev runs Kafka as a single `apache/kafka:3.8.0` container — a
direct image, no operator, because that's the simplest thing that gives a
working KRaft broker for local development (ADR-0003 already covers why
Kafka over RabbitMQ/SQS; this ADR is about *how* it runs on Kubernetes,
not *whether* to use Kafka at all).

On Kubernetes, running Kafka well by hand — StatefulSets, PodDisruptionBudgets,
rolling upgrades that respect in-sync replicas, broker configuration that
doesn't silently diverge from what's actually running — is a lot of
undifferentiated operational code to maintain for a five-topic, one-broker
workload. The Strimzi operator exists specifically to carry that
complexity: it turns "run Kafka" into "describe the Kafka cluster and the
topics I want, as Kubernetes custom resources," and reconciles the actual
StatefulSets/PodSets, Services, and configuration to match. Topics become
`KafkaTopic` resources instead of an imperative `kafka-topics.sh --create`
step — version-controlled, diffable, and re-creatable from the same YAML
every time, the same reasoning ADR-0001 already applied to choosing
Kubernetes-native primitives over hand-rolled infrastructure elsewhere in
this project.

The honest alternative worth naming and rejecting: run the same plain
`apache/kafka` image as a raw single-pod Deployment inside the app's own
Helm chart (this project's own Sprint 3 first draft, in fact — STMP-37's
kind-local manifests and STMP-39's first umbrella-chart pass both did
exactly this). That's simpler to read for someone who has never touched
Strimzi, and it was good enough to prove the rest of Sprint 3's platform
work. It's also not "ran Kafka on Kubernetes with an operator," which is
specifically the artifact this story exists to produce — a portfolio claim
needs to be true, and a raw Deployment pretending to be an operator-managed
cluster would not be.

## Decision

Install the Strimzi Cluster Operator via its own Helm chart
(`strimzi/strimzi-kafka-operator`), in its own `kafka` namespace, installed
and lifecycle-managed **separately** from the `stampede` umbrella chart —
an operator and the CRDs it owns should outlive any single `helm uninstall
stampede`, the same way a cloud provider's managed Postgres doesn't get
deleted when an application chart is removed.

Define the actual cluster as a `KafkaNodePool` (role: `controller,broker`,
replicas: 1) plus a `Kafka` custom resource, in KRaft mode (no ZooKeeper —
same principle as ADR-0003, one fewer stateful system to run). Topics are
five `KafkaTopic` resources plus their five `.dlq` siblings, matching
CLAUDE.md §6's registry exactly (partition counts included) — not the six
some AC prose generalized it to; it's five named topics, with ".dlq
variants" as the collective sixth bullet, not a sixth named topic.

**Honest scale note, stated plainly because a viva examiner will ask:**
this is a single-broker cluster. `replicas: 1` on the `KafkaNodePool`,
`default.replication.factor: 1`, `min.insync.replicas: 1`. **RF=3 across
three brokers is the production answer** for a Kafka cluster that needs to
survive losing a node without losing data or availability — this isn't
that. One broker is one failure domain; losing that pod loses the broker
until Strimzi restarts it (which it does — see the recovery runbook), and
there is no replica to fail over to in the meantime. That's an accepted,
named trade-off for a portfolio project proving the operator pattern
itself, not a production topology, and the honest version of this ADR says
so instead of describing a one-node cluster in production-cluster language.

## Consequences

**What this buys:** a real, reconcilable Kafka deployment managed the way
a production one actually would be — declarative cluster and topic
specs, automatic pod recovery, Prometheus metrics wired through the
operator's own JMX exporter config — all verifiable by actually doing it
rather than describing it.

**What this costs:**

- **No redundancy.** Already covered above; the single most important
  caveat in this whole document.
- **One more moving part to understand.** The operator itself needs its
  own CRDs installed cluster-wide before any `Kafka`/`KafkaTopic` resource
  can be applied — a dependency this project's `platform/kafka/README.md`
  documents as a manual one-time step, not something `helm install
  stampede` handles, deliberately (an app release shouldn't be able to
  accidentally take the operator, and every other Kafka-backed workload
  that might someday share this cluster, down with it).
- **Kafka version drift from compose-dev.** This Strimzi release only
  supports Kafka 4.2.x/4.3.x — compose-dev's `apache/kafka:3.8.0` is not
  one of them. The broker version running in Kubernetes (4.3.1) and the
  one running in compose-dev (3.8.0) are genuinely different Kafka major
  versions now; nothing in this project's client code depends on
  version-specific broker behavior, but it's a real discrepancy worth
  tracking if that ever stops being true.
