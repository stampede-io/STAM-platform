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
