# ADR-0006: One Postgres Instance, Five Isolated Databases

**Status:** Accepted
**Date:** 2026-10-07
**Author:** Pulith Thewmika

## Context

compose-dev runs five separate Postgres containers — one per DB-owning
service (`identity`, `catalog`, `booking`, `payment`, `notification`) —
because that costs nothing extra on a laptop and keeps each service's own
Dockerfile-free dev loop simple. CLAUDE.md documents that as the
architecture, and it stays true for local development; this ADR doesn't
change compose-dev.

Kubernetes changes the calculation. A managed Postgres instance (Azure
Database for PostgreSQL, even on the cheapest burstable tier) runs
somewhere around $13-15/month. Five of them, one per service, is
$65+/month — real money for a solo portfolio project whose whole point is
demonstrating the pattern, not paying for five lightly-loaded database
servers that between them use a fraction of one instance's capacity.

The question this ADR actually answers: does "database-per-service"
*require* five separate server processes, or is the ownership boundary —
no service reads or writes another's tables, no cross-service foreign
keys, each service's schema evolves independently — something Postgres can
enforce inside one instance just as strictly?

It's the latter. Postgres's own database/role/grant model gives exactly the
isolation database-per-service is actually for:

- A role can be denied `CONNECT` on every database except the one it owns
  (`REVOKE ALL ON DATABASE x FROM PUBLIC`, then grant only to that
  database's own role). A compromised or buggy `catalog_user` credential
  can't even open a connection to `booking_db`, let alone query it.
- Nothing about Flyway, JPA, or `ddl-auto: validate` (CLAUDE.md §4.8)
  changes — each service still only ever sees its own schema, under its
  own credentials, and has no idea the others exist.
- The "ownership boundary" people actually mean by database-per-service —
  no shared tables, no cross-service transactions, independent migrations
  — was never about how many `postgres` processes are running. That part
  was always a deployment-topology choice, not the architectural one.

## Decision

Run **one** Postgres instance in the Kubernetes cluster (a single-replica
`StatefulSet` with one 64Gi PVC), hosting **five** databases —
`identity_db`, `catalog_db`, `booking_db`, `payment_db`, `notification_db`
— each with its own non-superuser role that can connect to, and only to,
its own database.

A post-install Helm hook Job creates the five databases, the five roles,
and the grants/revokes on first install. Every service's own chart
(STAM-51) gets its `DB_HOST`/`DB_NAME` pointed at this shared instance via
the umbrella chart's `values.yaml`, rather than any change to that
service's own defaults — the service itself has no idea whether it's
talking to a dedicated instance or a shared one, which is exactly the
point: the ownership boundary is invisible to the service, enforced
entirely at the Postgres permission layer.

compose-dev is unaffected and keeps its five separate containers — this
decision is scoped to the Kubernetes deployment (`platform/charts/stampede`)
only, where the cost difference is real.

## Consequences

**What this buys:** roughly 80% of the managed-Postgres cost of the
five-instance alternative, for a workload where five services sharing one
small instance is genuinely sufficient — nothing here is remotely close to
needing its own dedicated server's full capacity.

**What this costs:**

- **A shared failure domain.** One Postgres pod down means all five
  services lose their database at once, where five separate instances
  would only take down whichever one failed. For this project's scale and
  purpose, that trade is worth it; it would not be once any one service's
  load justified isolating its blast radius.
- **A shared resource pool.** A connection-pool-exhausting bug in one
  service, or a slow query holding locks, can degrade another service's
  queries on the same instance — real noisy-neighbor risk that five
  separate instances don't have. `HIKARI_MAX_POOL` tuning (already done
  per-service, e.g. booking's 200-connection pool for flash-sale
  contention — CLAUDE.md §8) now needs to account for the other four
  services' pools too, not just its own instance's limits.
- **A credential-leak blast radius that's still contained, but less
  obviously so.** The Postgres-level `REVOKE`/`GRANT` genuinely stops a
  leaked `catalog_user` credential from reaching `booking_db` — but it's a
  permission the admin-run init Job has to get right, not a hard boundary
  like "this service's traffic physically cannot reach that server." A
  misconfigured grant is a real, if narrow, risk that separate instances
  structurally don't have.
- **No HA.** A single-replica StatefulSet has no failover. Acceptable for
  this project's scope; a real production system handling the same five
  databases would want at least a primary/replica pair, which changes the
  cost math back toward "maybe not so cheap after all" — the honest
  caveat on this whole trade-off.

Five managed servers ≈ $65+/month. Database-per-service is an ownership
boundary, not a hardware boundary. The trade-off — cheaper, shared failure
domain, shared resource pool, no HA — is documented here deliberately
because it's the kind of decision that looks obviously wrong at
true-production scale and is obviously right at this project's scale, and
a reader (or a viva examiner) should be able to tell which one of those we
are from reading this, not from guessing.
