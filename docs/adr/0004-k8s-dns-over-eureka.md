# ADR-0004: Kubernetes DNS over Eureka for Service Discovery

**Status:** Proposed (placeholder — full decision in Sprint 3)
**Date:** 2026-07-15
**Author:** Pulith Thewmika

## Context

Stampede currently uses Spring Cloud Netflix Eureka for service discovery. Each service registers itself with a Eureka server on startup and queries Eureka to resolve other services' network locations. This made sense when we started: Eureka is well-integrated with Spring Boot, requires minimal configuration, and works identically in Docker Compose and production.

However, we are planning to deploy to Kubernetes, which provides its own service discovery mechanism through DNS and the `Service` resource. In Kubernetes, when we create a `Service` named `stam-booking` in namespace `stampede`, every pod in the cluster can reach it at `stam-booking.stampede.svc.cluster.local` (or just `stam-booking` within the same namespace). Kubernetes handles health checking, load balancing, and deregistration of unhealthy pods natively through readiness probes and endpoint controllers.

Running Eureka on top of Kubernetes means maintaining two overlapping service registries — Kubernetes knows about every pod through its own control plane, and Eureka independently tracks the same services through heartbeats. This creates several problems that will be detailed in the full ADR when we make the migration in Sprint 3:

- Dual registration overhead and potential for the two registries to disagree about which instances are healthy.
- Eureka's self-preservation mode (designed for network partitions) can keep stale entries alive in ways that conflict with Kubernetes' own pod lifecycle.
- An extra infrastructure component (the Eureka server) that needs to be deployed, monitored, and kept highly available, duplicating what the platform already provides.
- Spring Cloud Eureka client dependencies in every service, adding startup time and configuration surface.

The forces pushing toward Kubernetes-native DNS: eliminating the redundant registry, leveraging the platform's built-in health checking, reducing per-service dependencies, and simplifying the deployment topology.

## Decision

*To be completed in Sprint 3 when we execute the migration from Eureka to Kubernetes-native service discovery.*

## Consequences

*To be completed in Sprint 3.*
