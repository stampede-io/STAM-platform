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
