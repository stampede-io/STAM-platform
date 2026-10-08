# stampede — platform umbrella chart

One Helm install deploys the whole platform: all 6 services plus the shared
infra none of them own individually (Kafka, Redis, and — per
CLAUDE.md's five-separate-databases invariant — one Postgres instance per
DB-owning service).

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

```bash
cd platform/charts/stampede
helm dependency update                    # pulls all 6 from GHCR (AC2)
helm lint .                                # AC7
helm template . --debug                    # AC5 — valid YAML, no errors

helm install stampede .                              # local/kind defaults
helm install stampede . -f values-staging.yaml       # staging overrides
helm install stampede . -f values-prod.yaml           # prod overrides (AC4)

helm test stampede                         # AC6 — curls gateway's own health endpoint
```

`values.yaml`'s defaults target a throwaway cluster (kind, or staging without
the overrides file): one replica each, `emptyDir` Postgres volumes, no
persistence. `values-prod.yaml` bumps replicas and resources and pins real
image tags — never `latest` (CLAUDE.md §10).

## What this chart does NOT do yet

- **Secrets** are plain `Secret` resources this chart creates directly with
  placeholder dev credentials (`changeme`) for each database. Sealed Secrets
  lands in STMP-45 — until then, this is explicitly not production-safe, and
  `values-prod.yaml` doesn't pretend otherwise.
- **Persistence**: every Postgres uses an `emptyDir` volume. Fine for a
  kind/staging smoke test, loses all data on pod restart — a real PVC is a
  prerequisite for using this chart against anything that needs to keep
  data, prod included.
