# Runbook

Operational notes for things that will actually happen, written from
having made them happen on purpose and watched what the system did.

## Kafka broker pod killed (Strimzi, STAM-53)

**Scenario:** the `stampede-broker-0` pod (the single KRaft broker,
managed by the Strimzi operator in the `kafka` namespace) dies — OOMKilled,
node drain, `kubectl delete pod`, anything that takes the pod away without
touching the `Kafka`/`KafkaNodePool` custom resources.

**What happens, unprompted:** the broker runs as a `StrimziPodSet`-managed
pod (Strimzi's own StatefulSet-like controller, not a raw Deployment or a
plain `StatefulSet`). Kubernetes' own pod controller plus the Strimzi
operator's reconciliation loop recreate the pod against the same PVC
(`storage.deleteClaim: false` in `platform/kafka/kafka-cluster.yaml` — the
20Gi volume survives the pod, so the recreated broker rejoins with its
existing log segments, not an empty disk). No one needs to run a command
for this to happen; it's what "managed by an operator" means in practice,
and AC5 exists specifically to prove it rather than assert it.

**Verify it yourself:**

```bash
kubectl -n kafka delete pod stampede-broker-0
kubectl -n kafka get pods -w   # watch it go Terminating -> gone -> ContainerCreating -> Running
kubectl -n kafka get kafka stampede   # READY should go back to True once it rejoins
```

**What does NOT recover itself:** the `kafka` namespace and the Strimzi
operator's own CRDs/Deployment. Deleting those is deleting the operator,
not testing it — recovering from that is a full reinstall
(`platform/kafka/README.md`), not a runbook step.

**Honest limit:** this is a single-broker cluster (ADR-0007). "The
operator restarts it and the cluster recovers" is true and demonstrated
above — what it does *not* mean is zero downtime. Between the pod dying
and the recreated one rejoining, there is no second broker to fail over
to, so topic traffic is unavailable for that window. A production RF=3
cluster wouldn't have that gap; this one, honestly, does.

## Sealed Secrets key rotation (STAM-57)

**What the key actually is:** the controller holds its active signing
key as a plain `Secret` in `kube-system`, labelled
`sealedsecrets.bitnami.com/sealed-secrets-key=active`. Every
`SealedSecret` anyone has ever committed was encrypted against *some*
version of this key's public half. By default the controller mints a
new key every 30 days on its own and keeps old keys around (just not
labelled `active`) so SealedSecrets encrypted against them still
decrypt — rotation does not retroactively break anything already
committed, only changes what new `kubeseal --raw` calls encrypt
against.

**Back up the key (do this before anything else, and before it's
needed):**

```bash
kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  > sealed-secrets-key-backup-$(date +%F).yaml
```

That file *is* the ability to decrypt every secret in the cluster —
treat it like the credentials it protects: never commit it, store it
somewhere access-controlled and offline (a password manager vault or
an encrypted drive), and restrict who can run the command above (it
needs read access to `kube-system` Secrets, which is itself a
privileged capability).

**Force a rotation on demand** (rather than waiting for the 30-day
timer):

```bash
kubectl delete secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key=active
kubectl rollout restart deployment -n kube-system sealed-secrets-controller
```

The controller generates a fresh active key on restart. Existing
`SealedSecret` resources keep working unchanged — they decrypt against
whichever key version they were encrypted with, and the controller
still holds that old key, just no longer `active`.

**Re-encrypt existing secrets after rotation** — only needed if the
goal is to stop depending on the *old* key entirely (e.g. it may have
leaked, or a compliance window requires it), since the old key is what
makes the already-committed manifests still decryptable:

```bash
kubeseal --fetch-cert --controller-name sealed-secrets-controller \
  --controller-namespace kube-system > new-cert.pem
echo -n 'the-plaintext-value' | kubeseal --raw --cert new-cert.pem \
  --namespace apps --name my-secret
# replace the ciphertext in the committed SealedSecret manifest, commit, apply
```

Repeat per secret, confirm every `SealedSecret` in the repo has been
re-encrypted and reapplied (`SYNCED: True`), and only then delete the
old key version from `kube-system` — deleting it before every manifest
is re-encrypted makes those older manifests permanently undecryptable.

**Honest limit:** there is no scripted "rotate everything" command here
— `kubeseal` encrypts one key at a time, so re-encrypting N secrets is
N manual (or scripted-by-you) commands. For the handful of secrets this
project currently has, that's fine; it would need actual tooling before
this became a routine, low-friction operation at real scale.

## Symptom-based alerts (STAM-66)

Every rule lives in `STAM-gitops/observability/alerts.yaml` as a
`PrometheusRule` — the alert policy is reviewable and reversible via a
normal PR (AC5 of STAM-66), not clicked together in a UI. Sections below
are named exactly after each alert so its `runbook` annotation link lands
here directly.

### CheckoutLatencyHigh

**Means:** booking's p99 request latency has been above 300ms for 5
minutes straight (`http_server_requests_seconds_bucket{job="booking"}`).

**First look:** is this one slow endpoint or everything? Check the
booking RED dashboard (`STAM-gitops/observability/dashboards/red-per-service.json`)
filtered to `booking`. A single hot endpoint usually means a missing
index or N+1 query; a platform-wide rise usually means Postgres or the
booking→catalog Feign call (`CircuitBreakerIT`'s territory) is slow.

**Check:** `kubectl top pod -n <ns> -l app.kubernetes.io/name=booking`
for CPU/memory pressure (a symptom here, never the alert condition
itself — AC5), and the Resilience4j `catalogClient` circuit breaker's
state in `/actuator/health`.

### ErrorBudgetBurn

**Means:** a service's 5xx rate has been above 1% for 5 minutes. The
`{{ $labels.job }}` in the alert tells you which one.

**First look:** `kubectl logs` the affected service's pods, filtered to
ERROR level, and cross-reference the correlation ID of a failing request
(CLAUDE.md §4.6 — every log line should carry one) across services to
find where the chain actually breaks.

**Common causes seen in this project:** a downstream dependency down
(Postgres, Kafka, catalog) surfacing as 500s instead of the intended 503
circuit-open response; a bad deploy — if this fires during or right
after a canary step (STAM-63) or a blue-green promotion (STAM-64), that
canary/promotion is the first suspect, not a coincidence.

### ConsumerLagGrowing

**Means:** a Kafka consumer group's lag has been increasing for 10
minutes — consumers aren't keeping up with production.

**Honest limit, right now:** this alert's metric
(`kafka_consumergroup_lag`) isn't actually emitted yet — no lag exporter
(kafka-lag-exporter / kminion) is deployed. The rule is written against
the metric name a standard exporter would emit, so it activates the
moment one is added, rather than silently doing nothing with no record
of why. Until then, check lag by hand:
`kubectl exec -n kafka stampede-broker-0 -- bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --group <group>`.

**First look (once wired):** which topic, which group. A growing lag on
`reservations.events` usually means catalog's projector or notification's
consumer is stuck or crash-looping (check `PodCrashLoop` too) — not that
booking is producing too fast.

### DLQNotEmpty

**Means:** `payments.events.dlq` has at least one message — a consumer
gave up retrying after `booking.kafka.retry.max-attempts` (default 3)
exponential-backoff attempts (`KafkaConsumerConfig`'s
`DeadLetterPublishingRecoverer`).

**First look:** consume the DLQ topic directly and read the
`exception-class`/`exception-message`/`stack-trace` headers
`DeadLetterPublishingRecoverer` attaches to every DLQ record —
`PoisonMessageDlqTest` is the test proving this header shape, so it's
also the reference for what to expect.
`kafka-console-consumer.sh --bootstrap-server ... --topic payments.events.dlq --property print.headers=true`.

**This is investigate-by-hand, not self-healing** — nothing auto-drains
the DLQ (CLAUDE.md §4.5). `dlq_depth` (booking, STAM-398) only ever grows
until a human looks.

### SagaStuck

**Means:** the oldest non-terminal saga has been stuck for over 10
minutes (`saga_oldest_non_terminal_age_seconds`, STAM-399) — the exact
same condition `SagaRecoverySweep` already self-heals against every 60s
(`saga.recovery.stale-after`, default `PT10M`).

**First look:** if this alert is firing for more than a minute or two
past the threshold, the recovery sweep itself is the problem, not the
saga — check `SagaRecoverySweep` logs for `Recovery sweep: failed to
recover saga=...` and `BookingSagaOrchestrator`'s `recoverStaleSaga`
exceptions. `SagaRecoveryIT` is the flagship test proving the sweep
normally clears this on its own.

### CertExpiry

**Means:** a TLS certificate managed by cert-manager expires in under 14
days.

**Honest limit, right now:** cert-manager isn't deployed yet — STMP-43
(Ingress + TLS via DuckDNS + Let's Encrypt) is blocked on provisioning a
real domain. The rule is written against cert-manager's own
`cert_manager_certificate_expiration_timestamp_seconds` metric so it
activates the moment that story lands, rather than being silently absent
with no trace of intent.

### PodCrashLoop

**Means:** a pod in `apps`/`staging`/`prod` restarted more than 3 times
in 15 minutes (`kube_pod_container_status_restarts_total`, from
kube-state-metrics — already installed via kube-prometheus-stack).

**First look:** `kubectl describe pod` for the last termination reason —
`OOMKilled` means raise `resources.limits.memory` in that service's
`values*.yaml`, a non-zero exit with a stack trace in `kubectl logs
--previous` means an actual startup bug (STAM-446's booking
`ApplicationReadyEvent`/`HoldExpiryScheduler` race is exactly this kind
of crash-loop, already fixed as a reference case).

## Alertmanager routing (STAM-66 / AC4)

kube-prometheus-stack is a cluster-wide install, independent of the
`stampede` umbrella chart's lifecycle (same pattern as Strimzi and Argo
Rollouts) — see `platform/monitoring/README.md`. Its own
`alertmanagerSpec.config` (set via `platform/monitoring/values.yaml`, not
anything in `platform/charts/stampede`) defines two receivers, both
**off by default** until their Sealed Secret is actually populated with a
real address/webhook:

- **email**: SMTP relay, same Mailhog instance (`:8025`) as notification
  uses locally; a real SMTP relay in staging/prod via `smtp-secret`
  (Sealed Secret).
- **telegram**: a bot token + chat ID via `telegram-secret` (Sealed
  Secret) — Alertmanager's native `telegram_configs`, no custom webhook
  relay needed.

**Honest limit:** no real email address or Telegram bot has been
provisioned — doing so needs an actual account, which only the project
owner can create. The routing config, labels, and Sealed Secret
*placeholders* are all real and reviewable; the two secrets' actual
values are not.

## Postgres backup + restore drill (STAM-59)

Nightly `postgres-backup` CronJob (`platform/backup/postgres-backup-cronjob.yaml`)
runs at 02:00 UTC: `pg_dump` all 5 databases, gzip, upload to the
`stampede-backups` Azure Blob container (cool tier) as
`<date>_<db>.sql.gz`, authenticated via a service-principal Secret scoped
to just that container (`platform/backup/setup-backup-blob.sh` creates it
with least privilege, not a subscription-wide role). A 30-day lifecycle
rule on the container deletes anything older automatically — no manual
cleanup, no unbounded storage growth.

**Restore drill** — the actual procedure, run this after any backup you'd
trust in a real incident:

1. Create a scratch namespace: `kubectl create namespace restore-drill`.
2. Deploy a bare Postgres pod there (`kubectl run restore-pg --image=postgres:16-alpine --env="POSTGRES_PASSWORD=drill" -n restore-drill`).
3. Pull last night's dump down: `az storage blob download --account-name <acct> --container-name stampede-backups --name <date>_catalog_db.sql.gz --file ./catalog_db.sql.gz --auth-mode login`.
4. Copy it into the pod and restore: `kubectl cp ./catalog_db.sql.gz restore-drill/restore-pg:/tmp/` then `kubectl exec -n restore-drill restore-pg -- sh -c "gunzip -c /tmp/catalog_db.sql.gz | psql -U postgres"`.
5. Verify row counts match production for a couple of known tables (`SELECT count(*) FROM venues;` etc.) against the real `catalog_db` via `kubectl exec postgres-0`.
6. Tear down: `kubectl delete namespace restore-drill`.

**Drill run 2026-10-13** — steps 1, 2, and 4-6 were actually run against
this project's live `catalog_db` on kind-stampede, not just described:
`pg_dump`'d the real database, piped it straight into a scratch pod's
`psql` (stdin, not `kubectl cp` — Git Bash on Windows mangles `/tmp/...`
remote-path arguments into local Windows paths, so piping sidesteps it
entirely), and diffed row counts on `venues` (2 = 2) and `seats` (3 = 3)
against the real `catalog_db`. Exact match. Scratch namespace torn down
after.

**Honest limit:** step 3 (blob *download*) wasn't run against a real
Azure container this session, because no backup has actually landed in
Azure Blob yet — that needs `setup-backup-blob.sh` run once against a
real Azure subscription (creates the container, lifecycle policy, and
scoped service principal) and the resulting Secret created in-cluster,
the same gate as STAM-50's `terraform apply`. Everything else the drill
depends on — the dump is a faithful, restorable snapshot of real data —
is proven, not assumed.
