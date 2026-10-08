# Argo Rollouts controller (STAM-381)

Like Strimzi (`platform/kafka/`), the Argo Rollouts controller is **not**
part of the `stampede` umbrella chart — it's a cluster-wide CRD controller,
installed once per cluster, outside any app release's lifecycle. Deleting
the `stampede` Helm release should never be able to take it down.

## One-time: install the controller

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo
helm install argo-rollouts argo/argo-rollouts -n argo-rollouts --create-namespace
kubectl -n argo-rollouts wait --for=condition=Available deploy/argo-rollouts --timeout=120s
```

Verify:

```bash
helm list -n argo-rollouts
kubectl get pods -n argo-rollouts
kubectl get crd | grep argoproj.io
```

Expect `argo-rollouts` as a `deployed` Helm release, 2 controller pods
`Running`, and the `rollouts`/`analysistemplates`/`clusteranalysistemplates`/
`analysisruns`/`experiments` CRDs present.

## Who uses this

Booking's and payment's own Helm charts (STAM-382, in their own repos)
define `kind: Rollout` and `kind: AnalysisTemplate` resources that this
controller reconciles — nothing in the `stampede` umbrella chart itself
depends on this controller being installed; it's the resource kinds those
two service charts emit that do.

## Verified live (kind, 2026-10-08)

- `helm list -n argo-rollouts` → `argo-rollouts` chart `2.43.6`, app
  version `v1.10.0`, status `deployed`
- 2 controller pods `1/1 Running`
- a real canary `Rollout` + `AnalysisTemplate` pair (catalog's chart,
  ad hoc for this verification) was reconciled by this controller, and its
  `AnalysisTemplate`'s Prometheus query correctly matched a test pod's
  `rollouts-pod-template-hash` label via the ServiceMonitor relabeling rule
  in `platform/charts/stampede/templates/observability/servicemonitors.yaml`
  (STAM-63)
