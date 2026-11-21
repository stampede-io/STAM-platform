# Sealed Secrets (STAM-57 / STMP-45)

No plaintext credential ever enters git. The Sealed Secrets controller
runs once per cluster, in `kube-system` — like Strimzi
(`platform/kafka/README.md`), its lifecycle is independent of the
`stampede` app release; uninstalling the app must never be able to take
the controller (and therefore the ability to decrypt every secret in the
cluster) down with it.

## One-time: install the controller

The chart moved off its old Helm repo URL (`bitnami-labs.github.io/sealed-
secrets` 404s now) to Bitnami's OCI registry:

```bash
helm install sealed-secrets-controller oci://registry-1.docker.io/bitnamicharts/sealed-secrets -n kube-system
kubectl -n kube-system wait --for=condition=Available deploy/sealed-secrets-controller --timeout=120s
```

Get the `kubeseal` CLI (matches the controller's protocol version — check
`kubectl -n kube-system logs deploy/sealed-secrets-controller | grep vers`
if you're not on `kubeseal` v0.27.x) from the project's GitHub releases:
<https://github.com/bitnami-labs/sealed-secrets/releases>.

## Adding a secret (AC2)

```bash
echo -n 'my-plaintext-value' | kubeseal --raw \
  --controller-name sealed-secrets-controller \
  --controller-namespace kube-system \
  --namespace apps --name my-secret
```

That prints a ciphertext blob — safe to paste into a `SealedSecret`
manifest and commit:

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: my-secret
  namespace: apps
spec:
  encryptedData:
    password: <the ciphertext from kubeseal --raw>
  template:
    metadata:
      name: my-secret
      namespace: apps
    type: Opaque
```

`kubeseal --raw` encrypts one key at a time and is scoped (by default) to
the exact `namespace`+`name` pair given — a sealed value can't be copied
into a different Secret or namespace and still decrypt, which is why both
have to be supplied up front and must match the manifest above exactly.

Apply it; the controller decrypts it in-cluster and creates the real
`Secret`:

```bash
kubectl apply -f my-secret.sealed.yaml
kubectl -n apps get sealedsecret my-secret   # SYNCED: True once decrypted
kubectl -n apps get secret my-secret         # the real Secret, created by the controller
```

## Identity's JWT signing key (STAM-454)

Identity signs every access token with `IDENTITY_RSA_PRIVATE_KEY` (an RSA
PKCS#8 key, base64). Without it, identity generates a key per pod start. Its
`kid` is the key's thumbprint, so the gateway, catalog and booking refetch the
JWKS and keep working, but every token issued before a restart, a rollout or
the demo-reset CronJob stops validating. Two replicas would also sign with two
different keys. Give the cluster one key:

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
  | openssl pkcs8 -topk8 -nocrypt -outform DER | base64 -w0 \
  | kubeseal --raw --controller-name sealed-secrets-controller \
      --controller-namespace kube-system --namespace <ns> --name identity-db-secret
```

Add the result as `IDENTITY_RSA_PRIVATE_KEY` under `encryptedData` of the
`identity-db-secret` SealedSecret. Identity already loads that Secret through
`envFrom`, so no chart change is needed. Keep the pipe in one shell: the
plaintext key never touches disk. Identity logs `Signing JWTs with the
configured key, kid=…` at startup when it's picked up, and refuses to start
if the value isn't a valid PKCS#8 key.

## Verified live (kind, 2026-10-07)

- Controller installed via the OCI chart, `1/1 Running` in `kube-system`.
- Sealed a real value (`super-secret-db-password`) with `kubeseal --raw`,
  applied the resulting `SealedSecret`, confirmed `SYNCED: True`, and read
  the decrypted `Secret` back out — exact round-trip match.

## What this story does NOT do yet

This repo's existing plain `Secret` resources — the per-service DB
credentials and Postgres admin secret in
`platform/charts/stampede/templates/infra/postgres.yaml` (STAM-52), and
the Kafka/Redis infra that has none — are **not** converted to
`SealedSecret` in this PR, and that's a deliberate scope cut, not an
oversight:

`SealedSecret`'s `encryptedData` is a fixed ciphertext checked into git.
The umbrella chart currently *generates* those Secrets from plaintext
values in `values.yaml` (`changeme` placeholders) via Helm templating —
one `values.yaml` describing every environment's shape, with different
tags/replicas/resources layered on via `values-staging.yaml` / `values-
prod.yaml`. Converting to `SealedSecret` means the credential itself
becomes a static, pre-encrypted artifact per environment instead of a
templated value — a real redesign of how this chart's secrets flow, not
a drop-in swap of one resource kind for another. Doing it as a rushed
partial change here would risk breaking STAM-52's already-verified
Postgres credential flow for no real security gain (those are still
kind-local placeholder values). Converting it properly is follow-up work,
and the right time to do it is when real non-placeholder credentials
first need to go into a committed manifest — which per AC3 is really
about `STAM-gitops`, a repo that currently holds nothing but a `LICENSE`.
