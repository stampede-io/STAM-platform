# Kafka on Kubernetes — Strimzi (STAM-53 / ADR-0007)

Kafka here is **not** part of the `stampede` umbrella chart
(`platform/charts/stampede/`) — it's managed by the Strimzi operator,
installed once per cluster, outside any app release's lifecycle. Deleting
the `stampede` Helm release should never be able to take Kafka down with
it.

## One-time: install the operator

```bash
helm repo add strimzi https://strimzi.io/charts/
helm repo update strimzi
kubectl create namespace kafka
helm install strimzi-operator strimzi/strimzi-kafka-operator -n kafka
kubectl -n kafka wait --for=condition=Available deploy/strimzi-cluster-operator --timeout=120s
```

## Create the cluster and topics

```bash
kubectl apply -f platform/kafka/kafka-metrics-configmap.yaml
kubectl apply -f platform/kafka/kafka-cluster.yaml
kubectl -n kafka wait --for=condition=Ready kafka/stampede --timeout=300s
kubectl apply -f platform/kafka/kafka-topics.yaml
```

Verify:

```bash
kubectl -n kafka get kafka,kafkatopic,pods
```

All 10 `KafkaTopic`s (5 topics + their `.dlq` siblings — CLAUDE.md §6's
registry) should show `READY: True`.

## What each file is

| File | What |
|---|---|
| `kafka-cluster.yaml` | `KafkaNodePool` (1 replica, `controller,broker` roles, 20Gi persistent storage) + the `Kafka` CR itself, KRaft mode, RF=1 — honestly single-broker, see [ADR-0007](../../docs/adr/0007-strimzi-single-broker-kraft.md) |
| `kafka-topics.yaml` | the 10 `KafkaTopic` CRs |
| `kafka-metrics-configmap.yaml` | Strimzi's standard JMX-to-Prometheus exporter rules, referenced by `kafka-cluster.yaml`'s `metricsConfig` |

## Verified live (kind, 2026-10-07)

- `kubectl -n kafka get kafka stampede` → `READY: True`
- All 10 topics → `READY: True` with the partition counts above
- `kafka-console-producer.sh` / `kafka-console-consumer.sh` round-tripped a
  message through `reservations.events` (AC4)
- `curl localhost:9404/metrics` inside the broker pod returns
  `kafka_server_*` / `kafka_log_*` series per topic (AC3)
- `kubectl -n kafka delete pod stampede-broker-0` — the pod was recreated
  and back to `1/1 Running` in ~21s, `Kafka` status returned to
  `READY: True`, and the message produced before the delete was still
  there after (AC5 — the PVC survives the pod, `deleteClaim: false`)

Not yet verified: scraping those metrics from an actual Prometheus install
(STMP-53, not done yet) — AC3 only requires the metrics to *appear* at
`/metrics`, which they do; wiring a scraper to them is that later story's
job.

## Services connecting to this cluster

Every service's bootstrap address is overridden in the umbrella chart's
`values.yaml` to `stampede-kafka-bootstrap.kafka.svc.cluster.local:9092`
— the cross-namespace FQDN, since Kafka now lives in the `kafka` namespace
and the services don't.
