# Hardening audit (STAM-71)

I ran this audit on 2026-11-20 against the compose-dev stack built from `Dev`
on every repo. For each checklist item I either ran something and kept its
output, or pointed at the code or doc that proves it. An item I couldn't prove
is marked as a gap rather than ticked, and it's listed again under "Known
limitations" in the [README](../README.md#known-limitations).

**Legend:** ✅ proven by a run I kept the output of · 🟡 proven only partly or
statically (config, code, or a drill on kind instead of the real cluster) ·
❌ not proven.

Every drill script is in [`tools/hardening/`](../tools/hardening/) and
reruns against a live compose stack (`docker compose up -d --wait` in
`compose-dev/`). Their outputs from this audit are in
[`docs/hardening/evidence/`](hardening/evidence/).

The audit found five defects. Two of them are serious enough to have their own
Jira bug:

| Finding | Severity | Status |
|---|---|---|
| Outbox marked rows published before Kafka acked them, so a booking crash during a broker outage lost events for good | Highest | **Fixed** in [STAM-451](https://puliththewmika-dev.atlassian.net/browse/STAM-451), [STAM-booking#43](https://github.com/stampede-io/STAM-booking/pull/43) |
| A non-JSON record blocks a consumer's partition forever (no `ErrorHandlingDeserializer` anywhere) | High | **Fixed** in [STAM-452](https://puliththewmika-dev.atlassian.net/browse/STAM-452): all five consumer services |
| Identity's login form has CSRF disabled: a cross-site `POST /login` signs the victim in as the attacker | Medium | **Fixed** in [STAM-453](https://puliththewmika-dev.atlassian.net/browse/STAM-453) |
| Compose never gave catalog `JWK_SET_URI`, so every catalog request carrying a bearer token got 401 | Medium | **Fixed** in this PR (`compose-dev/docker-compose.yml`) |
| The frontend's nginx resolves `gateway` once at startup and returns 502 after the gateway container is recreated | Low (compose only) | Open, see AC3 |

---

## AC1: Security

| # | Item | Status | Proof |
|---|---|---|---|
| 1 | OAuth 2.1 PKCE end to end | ✅ | [`oauth-e2e-real.txt`](hardening/evidence/oauth-e2e-real.txt): Playwright drives the real SPA through the real gateway with no `page.route()` mocks (register → identity's `/login` → code → BFF token exchange → seat map → hold). [`pkce-login.mjs`](../tools/hardening/pkce-login.mjs) runs the same flow headless over raw HTTP, and every other drill logs in through it. |
| 2 | Refresh-token reuse drill | ✅ | [`refresh-reuse-drill.txt`](hardening/evidence/refresh-reuse-drill.txt): RT1 → 200 and rotated to RT2; replaying RT1 → 401 with the cookie cleared; the legitimate RT2 → 401 because the whole family is revoked. Identity logs `Refresh token reuse detected for family … revoking entire family`. Flagship test: `RefreshTokenRotationIT`. |
| 3 | RBAC negative (USER → 403) | ✅ | [before](hardening/evidence/rbac-and-login-csrf-drill-before-stam-453.txt) / [after](hardening/evidence/rbac-and-login-csrf-drill-after-stam-453.txt): a real USER token gets 403 on `POST /api/v1/venues` (ORGANIZER), while the public `GET` returns 200. Identity's ADMIN-only `PUT /api/v1/users/{id}/role` is denied too, but with a **302 to `/login`, not a 403**: identity has no bearer-token filter chain, so it ignores the JWT entirely. That's still a deny, but it also means an ADMIN can't call that endpoint with a JWT. **Finding (login CSRF), fixed:** the same script's cross-site `POST /login`, with an attacker origin and no CSRF token, was accepted (302 to `/` with a session), because identity's `SecurityConfig` disabled CSRF. Since [STAM-453](https://puliththewmika-dev.atlassian.net/browse/STAM-453) the login form carries a session-bound `_csrf` token and the same POST gets **403**. `/api/**` (JSON from the SPA through the gateway) stays exempt. The real browser journey and the PKCE drills still log in. |
| 4 | Rate limit: k6 burst gets 429 | ✅ | [`rate-limit-burst-k6.txt`](hardening/evidence/rate-limit-burst-k6.txt) ([script](../tools/hardening/rate-limit-burst.js)): 60 requests in about 0.2 s per limiter. Booking (burst 20 per user): **20 allowed, 40 got 429**. Identity (burst 10 per IP, 5/s refill): 15 allowed over 1.8 s, 45 got 429. Both match the configured buckets. The M2 report [`flash-sale-secured-20260822-m2.md`](../load-tests/results/flash-sale-secured-20260822-m2.md) still has `_TBD_` for its 429 counts; this run is the measurement it was missing. Flagship test: `RateLimitIT`. |
| 5 | TruffleHog history scan clean | ✅ | [`trufflehog-history-scan.txt`](hardening/evidence/trufflehog-history-scan.txt): TruffleHog 3.88.0 over the **full git history** of all 10 repos finds 0 verified and 0 unverified secrets. |
| 6a | `kubectl auth can-i` | ❌ | Needs the k3s cluster (blocked on `az login`, same as STAM-50). Static side: no service chart binds a Role to its pods' ServiceAccount, so they run with the namespace default SA and no RBAC grants. The only Roles are the demo-reset and DuckDNS CronJobs' own. Pods still mount the default SA token (`automountServiceAccountToken` isn't set to `false`). |
| 6b | NSG | 🟡 | [`platform/terraform/main.tf`](../platform/terraform/main.tf): inbound allows 80 and 443 from anywhere, and SSH 22 **only from `var.operator_ip`**. Nothing else is open. This is config only; I didn't read the applied NSG back from Azure. |
| 6c | Non-root pods | 🟡 | All six backend Dockerfiles have `USER 1001`. Every service chart's `deployment.yaml` sets `runAsNonRoot: true`, `readOnlyRootFilesystem: true` and `capabilities.drop: ["ALL"]`, and pods ran under it on kind ([kind README](../platform/kind/README.md)). Not re-checked on k3s. The frontend image (`nginx:alpine`) runs its master process as root, but it isn't deployed to the cluster. |
| 7 | CI gates on Trivy and TruffleHog | ✅ | [`ci-gating.txt`](hardening/evidence/ci-gating.txt): in [STAM-booking run 44749128866](https://github.com/stampede-io/STAM-booking/actions/runs/44749128866), Trivy **failed** on 2 HIGH CVEs in `snappy-java` and every publish step was skipped. After the pin, [run 44751563516](https://github.com/stampede-io/STAM-booking/actions/runs/44751563516) passed. On `main` ([gateway run 38480489581](https://github.com/stampede-io/STAM-gateway/actions/runs/38480489581)) the order is TruffleHog → Trivy → push image → push chart, and the push only runs after Trivy succeeds. PRs never publish. |
| 8 | Stripe: no PAN anywhere | ✅ | Code walk: the card is collected by Stripe Elements (`CardElement` in `STAM-frontend/src/pages/CheckoutPage.tsx`) and only the resulting `paymentMethodId` leaves the browser. Booking stores just that id (`SetPaymentMethodRequest`), and payment's `AuthorizeRequest` carries only it. Payment's schema (`V2__create_payments.sql`) has `psp_ref`, `status`, `amount_cents` and `currency`, with no card columns, and its header comment says so. A grep for card-number, CVC or PAN fields across payment, booking and the frontend's non-test code finds nothing. |

## AC2: Reliability

| Item | Status | Proof |
|---|---|---|
| Saga + compensation ITs | ✅ | `mvn -B verify` on booking: `BookingSagaHappyPathIT`, `PaymentFailedCompensationIT`, `HoldExpireMidSagaIT`, `LateAuthAfterExpiryIT` and `SagaRecoveryIT` are all green (local run for STAM-451 and CI on [STAM-booking#43](https://github.com/stampede-io/STAM-booking/pull/43)). |
| kill -9 mid-saga | ✅ | [`saga-crash-drill.txt`](hardening/evidence/saga-crash-drill.txt) ([script](../tools/hardening/saga-crash-drill.sh)): payment stopped, `submit-payment` → 202, saga `PAYMENT_REQUESTED`, `AuthorizePayment` acked by Kafka, **booking SIGKILLed**. Payment then restarts while booking is still down, booking restarts, and the saga resumes from Postgres plus the Kafka log alone: `COMPLETED/RESERVATION_CONFIRMED`, exactly 1 saga row, reservation `CONFIRMED`. |
| OutboxIT, and a crash during a broker outage | ✅ | `OutboxIT` (crash before publish) is green. The broker-down drill found that a crash *during* an outage lost events, because rows were marked published before Kafka acked them: [before](hardening/evidence/broker-down-drill-before-stam-451.txt), 0/4 events delivered. STAM-451 fixed that ([after](hardening/evidence/broker-down-drill-after-stam-451.txt): 0 rows marked while Kafka was down, 4/4 delivered after `kill -9`), and the new `OutboxBrokerOutageIT` fails on the old code. |
| Idempotent consumers | ✅ | Catalog's `processed_events` and notification's idempotency check are both keyed on the envelope's `eventId`. Payment keys on `correlationId` + command type. Since STAM-451, `eventId` is the outbox row id, so a resend is recognised as the same event (it used to be a new random id per send, which made a resend look new). `SeatAvailabilityReplayTest` replays from offset zero. |
| DLQ and poison test | ✅ | [before](hardening/evidence/poison-message-drill-before-stam-452.txt) / [after](hardening/evidence/poison-message-drill-after-stam-452.txt) ([script](../tools/hardening/poison-message-drill.sh)). A record that deserializes but can't be applied ends up in `payments.events.dlq` after retries. A record that **isn't JSON** used to fail before the error handler: catalog's and notification's partition stopped at lag 1, with about 19k `Consumer exception` lines every 10 s and nothing in the DLQ. [STAM-452](https://puliththewmika-dev.atlassian.net/browse/STAM-452) wrapped every consumer's deserializer in `ErrorHandlingDeserializer`. Now catalog and booking dead-letter the original bytes, payment, notification and identity log and skip, and every group stays at lag 0. `PoisonMessageDlqTest` and booking's `PaymentEventPoisonIT` cover both kinds. Payment, identity and notification still have no DLQ recoverer (CLAUDE.md §4.5). |
| Retry/backoff config + logs | ✅ | Booking and catalog: `DefaultErrorHandler` with `ExponentialBackOff` (1 s initial, ×2, 3 attempts) and a `DeadLetterPublishingRecoverer`, set in each `KafkaConsumerConfig`. Catalog marks unparseable payloads `NonRetryableProjectionException`. Notification: `FixedBackOff(1000, 2)` with no DLQ. The poison drill's booking log shows the retries at **+1.0 s, +2.0 s, +4.1 s**, then the DLQ. Sync path: Resilience4j `catalogClient` (count window 5, 60 % failure threshold, 10 s open), proven by `CircuitBreakerIT`. Outbox producer: `delivery.timeout.ms` 15 s; an unacked row is retried on the next poll (STAM-451). |
| Broker-down drill | ✅ | [`broker-down-drill-after-stam-451.txt`](hardening/evidence/broker-down-drill-after-stam-451.txt) ([script](../tools/hardening/broker-down-drill.sh)), phase A: Kafka stopped mid-sale, **8/8 holds still accepted** (the oversell guard and the outbox are plain Postgres), then 8/8 `SeatsHeld` events delivered after recovery, and catalog shows 8 HELD. Phase B is the crash case above. |

## AC3: Deployment

| Item | Status | Proof |
|---|---|---|
| Canary auto-rollback | 🟡 | [`devlog/stam-385-canary-rollback-drill.md`](devlog/stam-385-canary-rollback-drill.md): on kind with the real Argo Rollouts controller, a canary at 95 % errors failed `error-rate-below-1pct` analysis, aborted, and scaled to zero. I used a synthetic stand-in pod wired to the exact Rollout and AnalysisTemplate used by booking and payment. It found and fixed a real `canary-hash` bug. **No screen recording**, and not run on k3s. |
| `git revert` rollback | ❌ | Not recorded. The mechanism is documented in [STAM-gitops `docs/gitops.md`](https://github.com/stampede-io/STAM-gitops/blob/Dev/docs/gitops.md): staging auto-syncs, so a revert on `Dev` rolls back; prod needs a manual sync. A revert has never been timed end to end on a cluster. |
| Blue-green promote | 🟡 | `gitops.md` §"Verified live (kind, 2026-10-08)": a new revision served on `preview` while `active` kept the old one, the Rollout stayed `Paused` and never auto-promoted, and `kubectl argo rollouts promote` switched traffic. Tested with a throwaway Rollout using the gateway's exact `blueGreen` block, not the gateway itself. |
| Expand → migrate → contract | ❌ | No migration in any service follows it. Every Flyway change so far has been purely additive (booking `V1`–`V6`, payment `V1`–`V3`), so no deploy has had to run old and new code against one schema with a rename or drop. The org PR template asks for the pattern, but there's no worked example yet. |
| Restore drill | 🟡 | [`runbook.md` §Postgres backup + restore drill](runbook.md#postgres-backup--restore-drill-stam-59): on kind (2026-10-13) I dumped the live `catalog_db`, restored it into a scratch pod, and row counts matched (`venues` 2 = 2, `seats` 3 = 3). The Azure Blob download step has never run, because no backup has landed in Blob yet (needs `az login` and `setup-backup-blob.sh`). |

Also observed while running AC3 locally:
- **Frontend nginx DNS caching.** `STAM-frontend/nginx.conf` has `proxy_pass http://gateway:8080` with no `resolver`, so nginx keeps the gateway container's old IP after the gateway is recreated, and the SPA returns 502 until the frontend restarts. This only affects compose (the frontend isn't on the cluster). The fix is `resolver 127.0.0.11` plus a variable upstream.
- **Cold-start hold latency.** The first hold after the stack starts took more than 20 s (JIT, Hikari warm-up and the first Feign call to catalog), and nginx logged a 499. A warm rerun took 3.6 s for the whole journey. A flash sale straight after a deploy would hit this, so a warm-up step or a readiness gate that exercises the hold path is worth adding.

## What it would take to close the gaps

All four ❌/🟡 deployment items and `kubectl auth can-i` need the k3s cluster,
which is blocked on `az login`. The Blob restore step needs
`setup-backup-blob.sh` run once. The canary and revert recordings need a screen
recorder in the user's hands. Expand→migrate→contract needs a real rename or
drop, so it's best done as part of the next schema change rather than invented
for the audit.
