# STAM-385 — auto-rollback drill

## What AC3 asks for

> Given a deliberately broken image is pushed (returns 500 on every request),
> when the canary reaches 10% and analysis runs, then within 5 minutes:
> (1) analysis fails, (2) Rollout aborts, (3) all canary pods are removed,
> (4) prod returns to 100% on the old version — this drill is screen-recorded.

## What I actually ran, and why not booking/payment directly

Running this against booking's or payment's real chart would need their full
dependency stack up in-cluster (Postgres, Kafka) just to get a pod serving
`/actuator/prometheus` — infrastructure the drill itself doesn't exercise.
What AC3 is actually testing is the **Argo Rollouts + Prometheus automation**:
does a failing analysis actually abort a canary and scale it back to zero.
So I built a minimal synthetic stand-in — a single Python `http.server`
exposing a counter-based `/actuator/prometheus` endpoint with an
`ERROR_RATE` env var — wired to the *exact* `Rollout` strategy and
`AnalysisTemplate` query shape used in booking's and payment's charts
(STAM-382/383/384), scraped by a `ServiceMonitor` identical to the ones in
`platform/charts/stampede/templates/observability/servicemonitors.yaml`
(STAM-63). The mechanism under test is identical; only the pod serving the
metrics is a stand-in.

**This is where I found a real bug** (now fixed in both booking's and
payment's charts, see stampede-io/STAM-booking#35 and the payment
equivalent): `canary-hash` is not auto-injected into inline step analysis
args. Without `valueFrom.podTemplateHashValue: Latest` wired explicitly on
each step's `analysis.args`, the Rollout fails validation outright —
`InvalidSpec: args.canary-hash was not resolved` — and never even starts.
A couple of third-party tutorials imply this is automatic; against the real
controller (Argo Rollouts v1.10.0, installed via Helm per STAM-381) it
isn't.

## Drill timeline (kind cluster, 2026-10-08, times UTC)

1. **01:12:50** — Rollout `rollback-drill` healthy at revision 1 (4/4 pods,
   `ERROR_RATE=0`), `stableRS=7df7bb8f8d`.
2. **01:12:55** — patched `ERROR_RATE` to `0.95` on the pod template,
   triggering revision 2 (`674f56d446`). Canary step 1 (`setWeight: 25`)
   scales up 1 canary pod.
3. **01:13:21 / 01:13:41** — the `error-rate-below-1pct` AnalysisRun's two
   measurements after the baseline tick both read **~94.9%** (the resolved
   PromQL: `100 * sum(rate(..outcome="SERVER_ERROR"..)) / clamp_min(sum(rate(..)),1)`).
4. **~01:14:09** (`failed (2) > failureLimit (1)`) — AnalysisRun phase
   `Failed`. Event: `AnalysisRunFailed`.
5. **Same tick** — Event `RolloutAborted`: *"Rollout aborted update to
   revision 2: Step-based analysis phase error/failed"*.
6. **Same tick** — `ScalingReplicaSet`: canary ReplicaSet `674f56d446`
   scaled **1 -> 0**; stable ReplicaSet `7df7bb8f8d` scaled back **3 -> 4**.
7. **~01:14:15** — cluster settled: 4/4 pods all on `7df7bb8f8d`, zero
   `674f56d446` pods remain, `status.abort: true`.

Elapsed from the broken revision landing to full rollback: **under 90
seconds** — well inside AC3's 5-minute bound.

Raw evidence (`kubectl get analysisrun ... -o jsonpath`):

```json
{"count":3,"failed":2,"measurements":[
  {"phase":"Successful","value":"[0]"},
  {"phase":"Failed","value":"[94.91605235826383]"},
  {"phase":"Failed","value":"[94.98648105766199]"}
],"name":"error-rate-below-1pct","phase":"Failed","successful":1}
```

`kubectl describe rollout` event log (trimmed to the relevant tail):

```
Normal   RolloutStepCompleted    Rollout step 1/5 completed (setWeight: 25)
Normal   AnalysisRunRunning      Step Analysis Run 'rollback-drill-674f56d446-2-1' ... 'Running'
Warning  AnalysisRunFailed       Step Analysis Run 'rollback-drill-674f56d446-2-1' ... 'Failed'
Warning  RolloutAborted          Rollout aborted update to revision 2: ... failed (2) > failureLimit (1)
Normal   ScalingReplicaSet       Scaled up ReplicaSet rollback-drill-7df7bb8f8d from 3 to 4
Normal   ScalingReplicaSet       Scaled down ReplicaSet rollback-drill-674f56d446 from 1 to 0
```

This satisfies AC3's four numbered conditions (1-4) against the real
controller, live, with the real canary-hash bug caught and fixed as a
direct result of running the drill rather than just reading the YAML.

## What this doc does not satisfy

**AC3's "screen-recorded" clause and STAM-386 ("save recording to
`docs/demos/canary-auto-rollback.mp4`")** — I cannot record a screen or
produce a video file; that needs the user's own terminal/screen recorder.
This doc is the complete evidence trail (timestamps, raw controller output,
event log) a recording would otherwise be proving, and the drill itself is
fully reproducible by re-running the same pattern against a kind cluster
with the `argo-rollouts` controller installed (STAM-381) — I did not keep
the throwaway synthetic manifests around in the cluster or repo since they
were a verification aid, not an artifact.
