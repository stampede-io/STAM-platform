# stampede — platform umbrella chart

One Helm install deploys all 6 services plus the shared data-layer infra
none of them own individually: Redis, and, per
[ADR-0006](../../docs/adr/0006-single-postgres-five-databases.md), **one**
Postgres instance hosting five isolated databases (one per DB-owning
service, each with its own non-superuser role) rather than five managed
servers. compose-dev still runs five separate Postgres containers — that
decision is scoped to this chart's Kubernetes deployment only.

**Kafka is deliberately not part of this chart.** Per
[ADR-0007](../../docs/adr/0007-strimzi-single-broker-kraft.md), it's
managed by the Strimzi operator, installed once per cluster and
lifecycle-independent of any `stampede` release — see
[`platform/kafka/README.md`](../../kafka/README.md). Every service's
`KAFKA_BOOTSTRAP_SERVERS` is overridden here, in `values.yaml`, to that
cluster's cross-namespace bootstrap address.

## How a service's chart gets here

Each service (`gateway`, `identity`, `catalog`, `booking`, `payment`,
`notification`) ships its own `helm/` folder **in its own repo**, next to its
source — not here. On every merge to that repo's `main`:

1. Its CI checks that `helm/Chart.yaml`'s `version` and `appVersion` match
   `pom.xml`'s `project.version` — bumped in the same commit, or the build
   fails (AC8: this is the drift the polyrepo split makes possible, so it's
   a hard CI gate, not a convention).
2. `helm package` + `helm push` publish it to
   `oci://ghcr.io/stampede-io/charts` as an OCI artifact.

This chart's `Chart.yaml` declares all 6 as dependencies on that same OCI
registry — never as local subchart folders — which is the actual point of
the polyrepo move for Helm specifically: nothing here needs that service's
source checked out.

## Using it

Kafka first — see [`platform/kafka/README.md`](../../kafka/README.md); the
5 services that need it will crash-loop on an unresolvable bootstrap
address otherwise (the same failure mode STAM-49 hit before Kafka existed
anywhere in-cluster). Then:

```bash
cd platform/charts/stampede
helm dependency update                    # pulls all 6 from GHCR (AC2)
helm lint .                                # AC7
helm template . --debug                    # AC5 — valid YAML, no errors

helm install stampede .                              # local/kind defaults
helm install stampede . -f values-staging.yaml       # staging overrides
helm install stampede . -f values-prod.yaml           # prod overrides (AC4)

helm test stampede                         # AC6 — curls gateway's own health endpoint
./verify-db-isolation.sh                   # AC2 — each service's role can reach only its own DB
```

`values.yaml`'s defaults target a throwaway cluster (kind, or staging
without the overrides file): one replica per service. `values-prod.yaml`
bumps replicas and resources and pins real image tags — never `latest`
(CLAUDE.md §10).

Postgres is a single-replica `StatefulSet` with a 64Gi PVC (AC1); a
post-install Helm hook Job creates the five databases, five roles, and the
grants/revokes that enforce AC2's isolation — it only runs on first
install, not every upgrade. Redis also has a PVC (AC3) with
`--appendonly yes`, deployed as a `Deployment` with `strategy: Recreate`
rather than a `StatefulSet`, since a single `ReadWriteOnce`-backed replica
doesn't need stable per-pod identity, just a volume that doesn't try to
double-mount during a rolling update.

## Observability (STAM-63)

`templates/observability/servicemonitors.yaml` ships one Prometheus Operator
`ServiceMonitor` per service, labeled `release: prometheus` and relabeling
each pod's `rollouts-pod-template-hash` label onto the scraped series as
`rollouts_pod_template_hash` — this is what booking's and payment's canary
`AnalysisTemplate`s (STAM-382, in their own repos) query by. Two assumptions
this chart doesn't enforce and will fail silently if violated:

- kube-prometheus-stack's Prometheus CR must be installed with a Helm
  release named `prometheus` (the `release:` label kube-prometheus-stack's
  own `serviceMonitorSelector` matches on) and either
  `serviceMonitorNamespaceSelector: {}` (all namespaces) or this chart's
  namespace explicitly included — Prometheus Operator's default is
  same-namespace-only, which silently drops these ServiceMonitors with no
  error anywhere if kube-prometheus-stack was installed more restrictively.
- Every service's actuator port is `8080` (CLAUDE.md §8); if a service ever
  diverges, its `targetPort: 8080` entry here needs updating too.

## What this chart does NOT do yet

- **Secrets** are plain `Secret` resources this chart creates directly with
  placeholder dev credentials (`changeme`) for Postgres's admin role and
  every per-service role. Sealed Secrets lands in STMP-45 — until then, this
  is explicitly not production-safe, and `values-prod.yaml` doesn't pretend
  otherwise.
- **Postgres HA**: single replica, no failover — see ADR-0006's
  Consequences for why that's an accepted trade-off at this project's scale
  and wouldn't be at a larger one.
