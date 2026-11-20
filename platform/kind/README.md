# Local kind cluster (STAM-49, CNI updated STAM-58)

```bash
kind create cluster --config platform/kind/kind-config.yaml
```

## NetworkPolicy needs Calico — kindnet does not enforce it

`kind-config.yaml` sets `networking.disableDefaultCNI: true`. Without
that, kind installs kindnet, which provides pod networking but silently
**does not enforce NetworkPolicy** — every policy in
`platform/charts/stampede/templates/network-policies/` would apply
without error and do nothing, which is a much worse failure mode than
an error would be.

Install Calico once per cluster, right after creating it:

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
kubectl wait --for=condition=Ready pod -l k8s-app=calico-node -n kube-system --timeout=180s
```

## Verified live (kind + Calico, 2026-10-07)

Deployed label-matched busybox stand-ins for gateway/catalog/booking/
notification/an attacker pod/an ingress-nginx stand-in (no dependency on
the umbrella chart's OCI subcharts actually being published — a
separate, later concern) and confirmed every NetworkPolicy edge with
`platform/charts/stampede/verify-network-policies.sh`:

- attacker -> catalog: **blocked** (AC3)
- gateway -> catalog: **allowed**
- booking -> catalog: **allowed** (the documented sync hop)
- notification -> catalog: **blocked** (not gateway, not booking)
- attacker -> gateway: **blocked**
- ingress-nginx -> gateway: **allowed** (AC1)

STAM-450 (2026-11-20) added the SMTP edges, against the chart's own
`infra/mailhog.yaml` + `network-policies/mailhog.yaml` rendered with
`values-staging.yaml` into a `staging` namespace:

- notification -> mailhog:1025: **allowed** (a real SMTP session from a
  notification-labelled pod via the short name `mailhog` got `250 queued`)
- alertmanager (monitoring ns) -> mailhog:1025: **allowed** (a real
  `prom/alertmanager:v0.28.1` with `platform/monitoring/values.yaml`'s SMTP
  block delivered a test alert to the inbox; the old block failed with
  `'require_tls' is true (default)`)
- catalog, an attacker pod, and grafana in `monitoring` -> mailhog: **blocked**

Removing the two new policies turns both "allowed" checks into FAILs.

Also verified a real built image (catalog, with the STAM-58 Helm
`securityContext` applied: `runAsNonRoot`, `runAsUser: 1001`,
`readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]`, `/tmp`
mounted as an `emptyDir`) starts and runs cleanly under that
`securityContext` — Tomcat and Hibernate both write to `/tmp` at
startup, and both did so without a single permission error. The only
failure in that run was the Postgres connection, because the stand-in
pod was deliberately pointed at a non-existent `DB_HOST` — the point was
testing the filesystem/user restrictions in isolation, not the full app.
