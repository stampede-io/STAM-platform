# ADR-0004: Kubernetes DNS over Eureka for Service Discovery

**Status:** Proposed (placeholder — full decision in Sprint 3)
**Date:** 2026-07-15
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

*To be completed in Sprint 3 when we execute the migration from Eureka to Kubernetes-native service discovery.*

## Consequences

*To be completed in Sprint 3.*
