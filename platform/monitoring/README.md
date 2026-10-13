# Alertmanager routing (STAM-66 / AC4)

`values.yaml` is merged into the `kube-prometheus-stack` Helm release
(`alertmanager.*`) to route alerts by email and Telegram. The SMTP password
and Telegram bot token are never written here in plaintext -- they're
mounted from `alertmanager-secrets.yaml`'s SealedSecrets via
`alertmanagerSpec.secrets`, same pattern as the Postgres credentials in
`platform/charts/stampede/values.yaml`.

## Applying

```bash
helm upgrade prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring -f platform/monitoring/values.yaml --reuse-values
kubectl apply -f platform/monitoring/alertmanager-secrets.yaml
```

The alert rules themselves live in `STAM-gitops/observability/alerts.yaml`
as a `PrometheusRule` CR, picked up automatically by the same release's
`ruleSelector` -- see that file for `kubectl apply` instructions.

## Replacing the placeholder secrets

`alertmanager-secrets.yaml`'s `encryptedData` values decrypt to the literal
string `changeme-...`, not real credentials -- the committed file documents
the shape, not working routing. To seal real values against this cluster's
sealed-secrets controller:

```bash
kubectl create secret generic alertmanager-smtp -n monitoring \
  --from-literal=password='<real smtp password>' --dry-run=client -o yaml \
  | kubeseal --raw --scope cluster-wide --controller-namespace kube-system \
    --name alertmanager-smtp --namespace monitoring > alertmanager-secrets.yaml
# repeat for alertmanager-telegram's `token` key
```

The Telegram `chat_id: -1` in `values.yaml` is a second placeholder for the
same reason (`chat_id: 0` fails Prometheus Operator's own validation and
breaks the entire Alertmanager config, not just this receiver) -- replace it
with a real chat ID from `@getidbot` once a real bot exists.

## Tempo + Loki + Alloy (STAM-68)

Self-hosted, same reasoning as kube-prometheus-stack itself being
self-hosted rather than Grafana Cloud (STAM-66): no SaaS account the
project owner has to sign up for just to run the demo. Not part of this
release -- each is its own Helm install into the same `monitoring`
namespace, single-binary/single-replica (honest portfolio scale, same
framing as Strimzi's single broker):

```bash
helm repo add grafana https://grafana.github.io/helm-charts

# Tempo: OTLP receiver on 4317 (grpc) / 4318 (http) is what every
# service's OTEL_EXPORTER_OTLP_ENDPOINT points at. metricsGenerator
# writes span-derived metrics back into this same Prometheus, which is
# where exemplar linking actually originates from.
helm install tempo grafana/tempo -n monitoring -f platform/monitoring/tempo-values.yaml

# Loki: single-binary, filesystem storage -- chunksCache/resultsCache
# (memcached sidecars the chart adds by default) disabled, unnecessary
# extra pods at this traffic volume.
helm install loki grafana/loki -n monitoring -f platform/monitoring/loki-values.yaml

# Alloy: ships every pod's stdout to Loki, promoting the traceId and
# level fields already in each service's JSON log lines (STAM-67) to
# Loki labels -- that's what makes Tempo's tracesToLogsV2 "logs for this
# span" link actually filter correctly.
helm install alloy grafana/alloy -n monitoring -f platform/monitoring/alloy-values.yaml
```

`values.yaml`'s own `prometheus.prometheusSpec.enableFeatures:
[exemplar-storage]` and the `grafana.additionalDataSources` block (Tempo
+ Loki, plus a replacement default Prometheus datasource carrying
`exemplarTraceIdDestinations`) are the AC4 click-through wiring:
Prometheus exemplar dot → Tempo trace waterfall → "Logs for this span" →
Loki, filtered by `traceId`.

**Honest limit:** verified live that the OTLP receiver accepts spans and
that `kubectl exec ... curl` against each piece's own health endpoint
works; the full three-pane click-through (AC4) needs a real latency
spike with exemplars attached to actually exist in Prometheus first --
run a few minutes of real traffic through the cluster, then open
Grafana's Explore view on the Prometheus datasource, find an exemplar
dot on a histogram, and click through. Screen-recording that is
STAM-414, and needs a human at the keyboard, not something this session
automates.
