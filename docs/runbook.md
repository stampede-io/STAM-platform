# Runbook

Operational notes for things that will actually happen, written from
having made them happen on purpose and watched what the system did.

## Kafka broker pod killed (Strimzi, STAM-53)

**Scenario:** the `stampede-broker-0` pod (the single KRaft broker,
managed by the Strimzi operator in the `kafka` namespace) dies — OOMKilled,
node drain, `kubectl delete pod`, anything that takes the pod away without
touching the `Kafka`/`KafkaNodePool` custom resources.

**What happens, unprompted:** the broker runs as a `StrimziPodSet`-managed
pod (Strimzi's own StatefulSet-like controller, not a raw Deployment or a
plain `StatefulSet`). Kubernetes' own pod controller plus the Strimzi
operator's reconciliation loop recreate the pod against the same PVC
(`storage.deleteClaim: false` in `platform/kafka/kafka-cluster.yaml` — the
20Gi volume survives the pod, so the recreated broker rejoins with its
existing log segments, not an empty disk). No one needs to run a command
for this to happen; it's what "managed by an operator" means in practice,
and AC5 exists specifically to prove it rather than assert it.

**Verify it yourself:**

```bash
kubectl -n kafka delete pod stampede-broker-0
kubectl -n kafka get pods -w   # watch it go Terminating -> gone -> ContainerCreating -> Running
kubectl -n kafka get kafka stampede   # READY should go back to True once it rejoins
```

**What does NOT recover itself:** the `kafka` namespace and the Strimzi
operator's own CRDs/Deployment. Deleting those is deleting the operator,
not testing it — recovering from that is a full reinstall
(`platform/kafka/README.md`), not a runbook step.

**Honest limit:** this is a single-broker cluster (ADR-0007). "The
operator restarts it and the cluster recovers" is true and demonstrated
above — what it does *not* mean is zero downtime. Between the pod dying
and the recreated one rejoining, there is no second broker to fail over
to, so topic traffic is unavailable for that window. A production RF=3
cluster wouldn't have that gap; this one, honestly, does.
