# Local Kubernetes (kind) — catalog + booking

Sprint 3 precursor to Helm (STMP-39). Raw manifests, one kind cluster, two
services. No cloud spend, no Sealed Secrets yet (STMP-45) — the Secret
resources below are plain-text and kind-local only.

## 1. Create the cluster

```bash
kind create cluster --config platform/kind/kind-config.yaml
kubectl get nodes          # AC1: nodes Ready
```

Single control-plane node named `stampede`; kind removes the control-plane
`NoSchedule` taint by default, so it schedules workloads fine for local use.

## 2. Build and load the images

kind nodes don't see your local Docker image cache — build, then load each
image into the cluster explicitly:

```bash
# from the PolyRepo root, one level above each service repo
docker build -t catalog:local -f STAM-catalog/Dockerfile STAM-catalog
docker build -t booking:local -f STAM-booking/Dockerfile STAM-booking

kind load docker-image catalog:local --name stampede
kind load docker-image booking:local --name stampede
```

## 3. Apply manifests

Kafka first — it's shared cluster infra (both services need a resolvable
`kafka:9092`), so it lives in `platform/kind/` alongside the kind config, not
in either service's own repo:

```bash
kubectl apply -f STAM-platform/platform/kind/kafka.yaml
kubectl -n stampede wait --for=condition=Available deploy/kafka --timeout=90s
```

This also creates the `stampede` namespace. Then each service's own
manifests, from that service's own repo, under `<service>/k8s-local/`:

```bash
kubectl apply -f STAM-catalog/catalog/k8s-local/
kubectl apply -f STAM-booking/booking/k8s-local/
```

`kubectl apply -f <dir>/` applies every file in the folder in **alphabetical
order** — on a brand-new namespace this means `configmap.yaml` and
`deployment.yaml` are sent before `namespace.yaml` and fail with `NotFound`
on the very first apply. Applying Kafka's manifest first (which creates the
namespace) avoids that; if you hit it anyway, just re-run the same
`kubectl apply -f <dir>/` — it's idempotent.

Each folder: `namespace.yaml`, `configmap.yaml` (Spring profile, DB host,
Kafka bootstrap servers — AC4), `secret.yaml` (DB password, JWT signing key —
AC5), `postgres.yaml` (an in-cluster Postgres so the service can actually
start — Redis isn't deployed into kind, which is fine since nothing in the
readiness/liveness/startup groups below depends on it), `deployment.yaml`,
`service.yaml`.

Wait for everything to come up:

```bash
kubectl -n stampede get pods -w
```

**Known gotcha — Metaspace OOM under k8s.** Both images' `JAVA_TOOL_OPTIONS`
default to `-XX:MaxMetaspaceSize=128m` (fine in compose-dev). Under kind this
is too tight — `OutOfMemoryError: Metaspace` either crashes the app at
startup (observed on booking, loading Kafka client classes while building the
consumer) or surfaces later under request traffic (observed on catalog, after
it had already passed its probes once). Both Deployments override
`JAVA_TOOL_OPTIONS` to `-Xmx256m -XX:MaxMetaspaceSize=224m` for the kind-local
profile — see the `env:` block in each `deployment.yaml`. This is a kind-local
tuning fix only; it doesn't touch the shared Dockerfile default.

## 4. Probes (AC2) and resources (AC3)

Each Deployment wires Spring Boot Actuator's health groups to the three k8s
probe types:

| Probe | Path | Backed by |
|---|---|---|
| `startupProbe` | `/actuator/health/startup` | custom group, `include: readinessState` |
| `readinessProbe` | `/actuator/health/readiness` | built-in `readinessState` group |
| `livenessProbe` | `/actuator/health/liveness` | built-in `livenessState` group |

Enabled via `management.endpoint.health.probes.enabled: true` in each
service's `application.yml` — see `catalog/src/main/resources/application.yml`
and `booking/src/main/resources/application.yml`.

Every container requests `cpu: 100m, memory: 384Mi` and limits
`memory: 640Mi` with **no CPU limit** (CLAUDE.md invariant — a CPU limit
throttles under flash-sale load; a memory limit still protects the node from
a leak). Confirm with:

```bash
kubectl -n stampede describe pod -l app=catalog
kubectl -n stampede describe pod -l app=booking
```

## 5. Hit it locally (AC6)

```bash
kubectl -n stampede port-forward svc/catalog 8081:8080
curl http://localhost:8081/actuator/health
```

```bash
kubectl -n stampede port-forward svc/booking 8082:8080
curl http://localhost:8082/actuator/health
```

## 6. Tear down

```bash
kind delete cluster --name stampede
```

Nothing here is persisted outside the cluster (`postgres.yaml` uses
`emptyDir`, deliberately — see the `ponytail:` comment in each service's
`k8s-local/postgres.yaml`) — deleting the cluster is a clean, complete reset.
