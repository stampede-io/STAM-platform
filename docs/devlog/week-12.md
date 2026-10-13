# Week 12 — STMP-42: all 6 services on a real cluster, for the first time

**Date:** 2026-10-13
**Story:** STAM-54 / STMP-42 — all 6 services deployed via Helm, full saga works on cluster

## What actually happened

I deployed Strimzi Kafka, the shared Postgres, Redis, and all 6 application
services to `kind-stampede` — the local kind cluster that STMP-37/STMP-41's
raw manifests and Strimzi install had already set up, but that had never
actually run the application services themselves. Then I drove the real
happy path through it: register → PKCE login → create a venue/event/show as
an organizer → hold a seat as a different user → set payment method → submit
payment → watch the saga land on `CONFIRMED`.

It did not work on the first, second, or third attempt. Getting it to work
surfaced four genuine bugs, in order:

1. **`postgres-init`'s hook Job had no NetworkPolicy path to Postgres** (either
   side — its own egress, or Postgres's ingress). The install just hung for
   the full hook timeout with no indication that network policy was the
   cause. `services-egress-infra.yaml` / `infra-ingress.yaml` only ever
   covered the 5 named application services, never the one-shot init Job.
2. **Booking's and payment's `AnalysisTemplate` had no `count`** on either
   metric. Argo Rollouts rejects a metric with no count when it's referenced
   from a fixed-duration canary/blue-green step ("runs indefinitely") — both
   Rollouts sat at 0 pods, phase `Degraded`, from the moment they were
   installed. Nothing in CI catches this; `helm template` renders a
   perfectly valid `AnalysisTemplate` manifest, it's only invalid in the
   context of how the `Rollout` actually references it.
3. **`-XX:MaxMetaspaceSize=128m` is too tight now.** Booking crash-looped on
   a real `OutOfMemoryError: Metaspace` within minutes under real
   classloading — this sprint's additions (`micrometer-tracing-bridge-brave`,
   `logstash-logback-encoder`, the STAM-398 business metrics) pushed it over
   a limit that was already tight in July.
4. **Catalog's JWT validation has probably never worked against a real
   token.** It checked signatures against a hardcoded HMAC shared secret;
   identity (Spring Authorization Server) only ever issues RS256 tokens via
   JWKS. Not a wrong-secret problem — no secret value makes an HS256
   validator accept an RS256 token. The code's own comment gave away how
   this happened: *"HMAC-SHA256 secret used to validate JWTs until
   STAM-identity issues real ones"* — identity has for a while now, and
   nobody circled back to catalog's resource-server config. This one I only
   found because I kept going past the first `401` instead of assuming the
   token request was configured wrong.

All four are fixed and merged (STAM-booking#38, STAM-catalog#30/#31,
STAM-payment#20, STAM-identity#17, STAM-notification#13, STAM-platform#37).

## RAM usage (AC4)

Measured via Prometheus (`container_memory_working_set_bytes`, already
scraping this cluster from STMP-53), not `kubectl top` — no metrics-server is
installed on kind, and I'd rather reuse infra that's already there than add
one just to take a single reading.

| Scope | RAM |
|---|---|
| 6 app services (`apps` namespace) | ~2.49 GiB |
| Strimzi Kafka (`kafka` namespace, 1 broker) | ~1.47 GiB |
| **Subtotal — what STAM-54 actually adds** | **~3.87 GiB** |
| Postgres + Redis (counted inside `apps` above) | included |

That's comfortably under the "~6 GB on an 8GB VM" target in AC4, with real
headroom left for kernel + k3s overhead.

Not counted in that subtotal, because they're a different story's scope, not
this one's: `monitoring` (kube-prometheus-stack, ~0.92 GiB), `argocd`
(~0.16 GiB), `argo-rollouts` (~0.05 GiB). Those are already running on this
cluster from STMP-49/51/53/63 and would be part of a real production
footprint too, but attributing their cost to "deploying the 6 services" would
overstate what this story is actually responsible for. With everything
included the box this ran on was visibly under memory pressure during this
session (`docker ps` itself timed out repeatedly) — a genuine signal that a
single 8GB VM running the full stack (services + Kafka + the whole
observability/GitOps layer at once) will be tight, worth revisiting once
STMP-56 (OTel) adds a Tempo/trace pipeline on top.

Per-pod, for anyone tuning requests/limits later:

| Pod | RAM |
|---|---|
| booking | 535 MiB |
| catalog | 459 MiB |
| identity | 389 MiB |
| payment | 342 MiB |
| notification | 343 MiB |
| gateway | 254 MiB |
| postgres | 168 MiB |
| redis | 4 MiB |

Booking and catalog running heaviest tracks with them being the two services
that do the most (saga orchestration + Feign/circuit breaker; CQRS
projection + cache) — not a surprise, but worth a second look if the 768Mi
limit (raised from 640Mi this same session, see STAM-326) ever gets tight
again.

## Chart parity (AC3/STAM-329) — honest version

AC1 as written assumes `helm install stampede ./charts/stampede -f
values-prod.yaml` resolves all 6 service charts from GHCR via `helm
dependency update`. That doesn't work yet: the per-repo "publish Helm chart
to GHCR" CI step (STAM-51/.github#12) hasn't actually produced a package at
the `0.0.1-SNAPSHOT` ref the umbrella chart's `Chart.yaml` asks for —
`helm dependency update` fails with `not found` for all 6, not an auth
problem (confirmed: logged in to `ghcr.io` with a valid token, same error).

What I actually verified instead: each service's own local chart
(`STAM-<service>/helm/`) — the real committed chart source, not a copy —
installed directly against this cluster, config-wired the same way the
umbrella chart's `values.yaml` wires it (same `DB_HOST=postgres`,
`KAFKA_BOOTSTRAP_SERVERS=<strimzi-bootstrap-fqdn>`, same secret names). The
templates themselves are identical to what the umbrella chart would deploy;
only the dependency-resolution mechanism differs (direct `helm install
./STAM-<service>/helm` vs. the umbrella's `helm dependency update` +
`helm install ./charts/stampede`). So: **chart content parity, yes — the
"resolve from GHCR" plumbing, not yet.**

That gap is tracked as its own thing, not re-opened here: STAM-51's chart
publish is what needs fixing (why isn't the GHCR package appearing?), and
until it does, the umbrella chart can't be installed as AC1 literally
describes it on *any* cluster, kind or the real k3s VM.

## What's still open on this story

- The umbrella-chart-from-GHCR path (above) — blocked on STAM-51's publish
  step, not on anything in this story.
- AC5 (`helm uninstall && helm install` comes back working) — not yet
  exercised; next natural step once the GHCR path is sorted, since testing
  it against the manual per-service installs I used here would just be
  re-proving the same workaround, not the real flow.
- A confirmed reservation currently leaves the seat showing `HELD` in
  catalog forever, not `BOOKED` — found during this session's E2E run,
  tracked separately (projector never had a case for `ReservationConfirmed`)
  since it's a catalog projection gap, not a deployment one.
