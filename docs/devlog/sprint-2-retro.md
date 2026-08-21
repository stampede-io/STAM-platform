# Sprint 2 Retro — Frontend + Identity + Gateway

**Dates:** 2026-07-22 → 2026-08-22
**Goal:** Secured end-to-end product — React SPA with PKCE auth through an API gateway, rate limiting, Stripe integration, notification emails, and Playwright E2E proving the full journey works from a browser.

## Velocity

| Metric              | Planned | Actual | Notes |
|---------------------|---------|--------|-------|
| Story points        | 55      | 55     | All 13 stories (STMP-23 through STMP-35) landed. |
| Stories             | 13      | 13     | Zero carry-over into Sprint 3. |
| Sprint goal met?    | Yes     | Yes    | Full browser checkout journey works end-to-end; Playwright proves it nightly. |

## Sprint 2 stories delivered

| # | Story | Repo(s) |
|---|-------|---------|
| STMP-23 | Spring Authorization Server: OAuth2.1 + PKCE | STAM-identity |
| STMP-24 | Rotating refresh tokens with reuse detection | STAM-identity |
| STMP-25 | RBAC claims, @PreAuthorize, BOLA protection | STAM-identity |
| STMP-26 | Identity audit events → Kafka | STAM-identity |
| STMP-27 | Gateway: routes, JWT validation, correlationId | STAM-gateway |
| STMP-28 | Redis token-bucket rate limiting at gateway | STAM-gateway |
| STMP-29 | Eureka + Config Server (temporary — Sprint 3 replaces with K8s DNS) | STAM-platform |
| STMP-30 | Stripe test mode replaces mock PSP | STAM-payment |
| STMP-31 | Notification emails via Mailhog | STAM-notification |
| STMP-32 | React: seat-map grid with live availability polling | STAM-frontend |
| STMP-33 | React: checkout flow with hold countdown + payment UX | STAM-frontend |
| STMP-34 | React: PKCE auth integration (tokens in memory, refresh in httpOnly) | STAM-frontend |
| STMP-35 | Playwright E2E: happy-path, race, expiry, RBAC, rate-limit specs | STAM-frontend, STAM-catalog, STAM-platform |

## What went well

- **The auth stack came together cleanly.** Spring Authorization Server (STMP-23) was the riskiest story — I had never built a full OAuth2.1 server from scratch. The PKCE flow, rotating refresh tokens, and reuse-detection family revocation all worked on the first integration pass with the React SPA. The key decision was keeping tokens in memory (not localStorage) and refresh tokens in httpOnly cookies, which simplified the threat model.
- **Gateway as a single entry point simplified everything downstream.** Once STMP-27 landed, every backend service stopped needing its own JWT validation config. The gateway validates once, adds correlation IDs, and routes. Rate limiting (STMP-28) slots in naturally as a gateway filter. This is the architecture ADR-0004 was pointing toward.
- **Playwright E2E with mock API routes (STMP-35) gave fast, reliable tests.** Instead of waiting for the full compose stack to boot for every test run, the specs mock all API responses via `page.route()` interceptors. The nightly workflow runs them against the real stack separately. This gives two layers: fast local feedback and slow integration confidence.
- **Polyrepo branching discipline held.** Every story branched from Dev, PRs targeted Dev, and the diff-against-Dev check before opening PRs caught carried-over files twice. The workflow is now muscle memory.

## What slipped or hurt

- **ESLint vs Playwright fixture clash (STMP-35).** The `react-hooks/rules-of-hooks` rule flagged Playwright's `use` callback parameter as a React Hook call, failing CI on the first push. Fix was simple (exclude `e2e/` from the ESLint config) but burned a CI round-trip. Lesson: when adding a non-React test framework to a React project, exclude its directory from React-specific lint rules upfront.
- **Vite proxy ECONNREFUSED in E2E tests.** AuthProvider's mount-time refresh call hit the Vite proxy (forwarding `/api` to `localhost:8080`), causing all 20 E2E tests to time out with proxy errors when no backend was running. Solved by creating a global Playwright fixture that mocks the refresh endpoint for all tests. Lesson: any SPA feature that makes an API call on mount needs a mock in the E2E test harness.
- **JAVA_HOME still pointing to JDK 17.** Same issue from Sprint 1 — every Maven session in STAM-catalog needed `JAVA_HOME="/c/Program Files/Java/jdk-21"`. I documented it in CLAUDE.md but didn't fix the workstation config. Sprint 3 action: set up `.envrc` with direnv or fix the system default.
- **Config Server bootstrap was fragile.** Eureka + Config Server (STMP-29) added startup-order complexity in compose — services needed `depends_on` with health checks on both eureka and config-server before they could start. This is explicitly temporary (ADR-0004 flags it for removal in Sprint 3 when K8s DNS takes over).

## Surprises

- **React 19's `use()` hook and `react-refresh` had a subtle interaction** — exporting both `AuthProvider` and `useAuth` from the same file caused a react-refresh boundary violation. The fix was splitting `useAuth` into its own file. Not documented anywhere I could find; discovered through the Vite HMR warning.
- **Playwright's `addInitScript` only fires on full page loads, not SPA navigations.** This broke the happy-path integration test where Stripe.js was mocked via `addInitScript` after a `goto()`, but the SPA navigated to `/checkout` via React Router (no page load). Fix: call `addInitScript` before the first `goto()`.
- **Sprint 2 took longer than Sprint 1** despite fewer story points (55 vs 65). The identity/auth stories involved more research and unfamiliar libraries (Spring Authorization Server, PKCE, JWT). Sprint 1's stories were more "known territory" (JDBC, Kafka, saga patterns). Velocity in points was the same but wall-clock time was higher.

## Metrics

- **Unit tests:** 22 (frontend Vitest)
- **E2E tests:** 38 (20 chromium + 18 integration via Playwright)
- **Backend ITs:** All services green via Testcontainers
- **Secured k6 report:** See [`load-tests/results/flash-sale-secured-20260822-m2.md`](../../load-tests/results/flash-sale-secured-20260822-m2.md)

## Sprint 3 goal

**"Kubernetes-native deployment — kind locally, k3s in Azure, Helm charts, ArgoCD GitOps."**

Concretely: raw K8s manifests for catalog + booking on kind (STMP-37), Terraform for Azure VM + k3s (STMP-38), Helm umbrella chart with per-service subcharts (STMP-39), shared Postgres + Redis on cluster (STMP-40), Sealed Secrets (STMP-45), and ArgoCD app-of-apps (STMP-41). Eureka + Config Server get deleted (ADR-0004 fulfilled). The same zero-oversell bar applies; new target: `helm install stampede` deploys the full platform in one command.

Story-point budget: 50 (Sprint 3 stories are infrastructure-heavy with more unknowns around Terraform and Helm — keeping slack).

## Retro attendees

- Pulith Thewmika (solo)
