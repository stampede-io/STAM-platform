# Ingress + TLS (STAM-55)

No purchased domain — DuckDNS (free dynamic DNS) + cert-manager +
Let's Encrypt, same pattern as any other no-budget homelab/k3s setup.

## What's in this directory

| File | Purpose |
|---|---|
| `cluster-issuer.yaml` | cert-manager `ClusterIssuer` for Let's Encrypt via HTTP-01, solved through the nginx `IngressClass` |
| `stampede-ingress.yaml` | Routes `${DUCKDNS_HOSTNAME}` to `gateway-service:8080`, TLS terminated via the cert-manager-issued `stampede-tls` secret |
| `duckdns-refresh-cronjob.yaml` | Every 5 min, reads the ingress-nginx `LoadBalancer`'s external IP and pushes it to DuckDNS (AC5 — the VM's IP can change) |

## One-time setup (needs your DuckDNS account and the real k3s VM — not kind)

1. **Register a DuckDNS subdomain** at <https://www.duckdns.org> (sign in,
   pick a name, e.g. `stampede-api` → `stampede-api.duckdns.org`). This
   is a free account action only you can do.
2. Install NGINX Ingress Controller: `helm install ingress-nginx
   ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace`
   (on the real VM, `controller.service.type` stays the chart default
   `LoadBalancer` — k3s's own `klipper-lb` satisfies that using the
   node's own public IP; on kind there's no real LoadBalancer, which is
   why local testing here used `NodePort` instead, a kind-only
   difference, not a code change).
3. Install cert-manager: `helm install cert-manager jetstack/cert-manager
   -n cert-manager --create-namespace --set installCRDs=true`.
4. Apply `cluster-issuer.yaml` with `ACME_EMAIL` substituted for a real
   address (Let's Encrypt sends expiry notices there).
5. Create the DuckDNS token Secret: `kubectl create secret generic
   duckdns-credentials -n kube-system --from-literal=token=<your token
   from duckdns.org> --from-literal=domain=stampede-api`.
6. Apply `duckdns-refresh-cronjob.yaml`, then `stampede-ingress.yaml`
   with `${DUCKDNS_HOSTNAME}` substituted for the real hostname.
7. Within ~5 minutes, `curl https://stampede-api.duckdns.org/api/v1/shows`
   should return a valid Let's Encrypt cert, no `--insecure` needed (AC4).

## Verified locally on kind-stampede (2026-10-13)

- NGINX Ingress Controller installs cleanly via Helm (`NodePort` mode,
  since kind has no real `LoadBalancer`).
- `stampede-ingress.yaml` and `duckdns-refresh-cronjob.yaml` both pass
  `kubectl apply --dry-run=client` against the live API server — schema-
  correct, ready to apply for real.

## Not verifiable without the real VM + a DuckDNS account

cert-manager's HTTP-01 challenge needs Let's Encrypt's own servers to
reach port 80 at the public hostname — unreachable from kind (no public
IP) and from any machine without a real DuckDNS registration. Steps 1-7
above are the actual remaining work, gated on your DuckDNS account and
the Terraform-provisioned VM (STAM-50) existing first.
