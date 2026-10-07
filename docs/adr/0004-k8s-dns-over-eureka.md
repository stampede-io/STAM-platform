# ADR-0004: Kubernetes DNS over Eureka for Service Discovery

**Status:** Accepted
**Date:** 2026-10-07
**Author:** Pulith Thewmika

## Context

Eureka and Config Server are added in Sprint 2 as a learning exercise. They will be deleted in Sprint 3 when Kubernetes DNS and ConfigMaps replace them.

I wanted to understand what Kubernetes replaces before we get there, so I added Spring Cloud Netflix Eureka and Spring Cloud Config Server to the dev compose stack. Every service now registers with a Eureka server on startup and can resolve other services through the Eureka registry. A centralized Config Server serves shared configuration (eureka client settings, actuator exposure) from a native file backend, so services pull part of their config from the network rather than relying entirely on local application.yml files.

This works fine for local development. Each service discovers its peers through Eureka's registry instead of relying on hardcoded Docker Compose DNS names, and the Config Server centralizes the boilerplate that would otherwise be duplicated across five application.yml files. The Eureka dashboard at `localhost:8761` gives a quick visual check that all services registered correctly.

However, none of this survives contact with Kubernetes. In a Kubernetes cluster, every `Service` resource gets a DNS entry automatically — `booking.stampede.svc.cluster.local` resolves to the correct pod IPs without any application-level registry. Kubernetes readiness probes, endpoint controllers, and the kube-proxy handle health checking, load balancing, and deregistration of unhealthy pods. Running Eureka on top of that would mean maintaining two overlapping registries that can disagree about which instances are healthy.

Similarly, Kubernetes ConfigMaps and Secrets replace the Config Server pattern. Instead of services fetching config over HTTP from a centralized server at boot time, the cluster injects configuration as environment variables or mounted files — no extra infrastructure component to deploy, monitor, or secure.

The forces pushing us toward the Kubernetes-native approach:

- Eliminating the redundant service registry reduces operational surface and removes a potential source of split-brain between Eureka's view and Kubernetes' view of healthy pods.
- Eureka's self-preservation mode, designed for network partitions in traditional deployments, can keep stale entries alive in ways that conflict with Kubernetes' pod lifecycle.
- Removing `spring-cloud-starter-netflix-eureka-client` and `spring-cloud-starter-config` from every service simplifies the dependency tree and speeds up startup.
- ConfigMaps are native to the deployment platform and integrate with GitOps workflows (ArgoCD) without an intermediary server.

## Decision

Delete `spring-cloud-starter-netflix-eureka-client` and
`spring-cloud-starter-config` from all six backend services (`gateway`,
`identity`, `catalog`, `booking`, `payment`, `notification`), and delete
the `eureka-server` and `config-server` modules themselves, plus
`config-repo/`, from the `platform` repo. Every `EUREKA_CLIENT_SERVICE_URL_
DEFAULTZONE` and `SPRING_CONFIG_IMPORT` environment variable goes with
them — there is nothing left for either to point at.

Service discovery becomes whatever the deployment target already gives
for free: Kubernetes Service DNS (`http://catalog:8080` inside a
namespace, as every service's own Helm chart default already assumes —
STAM-51) on K8s, and compose's own container-name DNS in `compose-dev`.
Neither needed Eureka to begin with; registering with it was purely
additive overhead once the actual lookup already worked without it.

Configuration becomes ConfigMaps and Secrets (K8s) or compose's own
`environment:`/`.env` (compose-dev) — both already what every service
reads in practice, since `SPRING_CONFIG_IMPORT` was declared
`optional:configserver:...`, meaning a Config Server that was unreachable
(the common case whenever a service started before it, or ran outside
compose entirely — this project's `./mvnw spring-boot:run` dev loop,
every test suite) was silently skipped. The decision here just stops
carrying a dependency that was already not load-bearing in practice.

### Polyrepo mechanics (STAM-56)

This is not one deletion PR, it's seven — one per service repo for the
client-side removal, plus one on `platform` for the server-side
deletion and the `compose-dev` cleanup. A monorepo would show this as a
single commit; across nine independent repos, the same change is
necessarily seven coordinated ones, linked by this ADR and by a shared
Jira reference (STAM-56) since git itself has no mechanism to show a
cross-repo change as atomic. The safe merge order is client-side first,
everywhere: every service repo's removal lands before `platform`'s
central deletion, so nothing is ever mid-migration pointing at an
Eureka/Config Server that's already gone from `compose-dev`.

## Consequences

**What this removes:**

- Two fewer containers in `compose-dev`'s already-long startup chain, and
  two fewer `depends_on: condition: service_healthy` edges every other
  service was carrying (known issue #9 in `CLAUDE.md` §13 — this ADR is
  what resolves it).
- Two fewer dependencies per service's `pom.xml` (ten across six repos),
  and the transitive `bcprov-jdk18on` CVE pin they required in four of the
  six (`catalog`, `identity`, `payment`, `notification`) — gone along
  with the `spring-cloud-dependencies` BOM import those four no longer
  need at all once Eureka and Config were their only reason to import it.
  `booking` and `gateway` keep the BOM; they still use
  `spring-cloud-starter-openfeign`/`-circuitbreaker-resilience4j` and
  `spring-cloud-starter-gateway-server-webflux` respectively.
- No Config Server pod to maintain, patch, or explain in a viva — one
  less moving part whose only job was proxying files Kubernetes'
  ConfigMap primitive already does natively.

**What this doesn't change:** nothing about how any service actually
*behaves*. Lookups and configuration values were already resolved the
same way before this ADR, in every environment that mattered (K8s DNS
already worked; `SPRING_CONFIG_IMPORT`'s `optional:` prefix meant Config
Server was never actually required). This is a deletion of unused
machinery, not a behavior migration — which is exactly why it was safe to
do in Sprint 3 rather than something that had to happen before any
service could run on Kubernetes.
