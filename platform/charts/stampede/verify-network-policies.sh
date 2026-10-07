#!/usr/bin/env bash
# STAM-58 / AC1, AC3: proves the NetworkPolicies in
# templates/network-policies/ actually block lateral movement, rather
# than asserting they do because the YAML looks right.
#
# Needs a NetworkPolicy-enforcing CNI (Calico — see platform/kind/README.md;
# kind's default kindnet does not enforce NetworkPolicy at all, so this
# script would report false "OK"s against it even with every file in
# templates/network-policies/ deleted).
#
# Deploys throwaway busybox pods labelled like the real workloads (no
# dependency on the umbrella chart's OCI subcharts actually being
# published, which is a separate, later concern) and uses `nc -z`'s
# timing as the signal: a NetworkPolicy DROP is a timeout (hits the
# `-w` wait); an ALLOWED flow with nothing listening is an immediate
# "connection refused". That distinction is reliable; parsing nc's
# stderr text across busybox/GNU variants is not. Cleans up its own
# pods on exit either way.
set -euo pipefail

NAMESPACE="${1:-apps}"
TIMEOUT=3

trap 'kubectl delete pod -n "$NAMESPACE" gateway-standin catalog-standin booking-standin notification-standin attacker-standin --ignore-not-found >/dev/null 2>&1; kubectl delete pod -n ingress-nginx ingress-nginx-standin --ignore-not-found >/dev/null 2>&1' EXIT

kubectl create namespace ingress-nginx >/dev/null 2>&1 || true

standin() {
  local name="$1" ns="$2" label="$3"
  kubectl run "$name" -n "$ns" --image=busybox --labels="$label" --command -- sleep 3600 >/dev/null
}

standin gateway-standin "$NAMESPACE" app.kubernetes.io/name=gateway
standin catalog-standin "$NAMESPACE" app.kubernetes.io/name=catalog
standin booking-standin "$NAMESPACE" app.kubernetes.io/name=booking
standin notification-standin "$NAMESPACE" app.kubernetes.io/name=notification
standin attacker-standin "$NAMESPACE" app=attacker
standin ingress-nginx-standin ingress-nginx app=ingress-nginx-standin

kubectl wait --for=condition=Ready pod --all -n "$NAMESPACE" --timeout=60s >/dev/null
kubectl wait --for=condition=Ready pod --all -n ingress-nginx --timeout=60s >/dev/null

CATALOG_IP=$(kubectl get pod catalog-standin -n "$NAMESPACE" -o jsonpath='{.status.podIP}')
GATEWAY_IP=$(kubectl get pod gateway-standin -n "$NAMESPACE" -o jsonpath='{.status.podIP}')

# check SRC_POD PORT EXPECT("ALLOWED"|"BLOCKED") DESCRIPTION
check() {
  local src="$1" ns="$2" ip="$3" port="$4" expect="$5" desc="$6"
  local start elapsed
  start=$(date +%s%N)
  kubectl exec -n "$ns" "$src" -- nc -w "$TIMEOUT" -z "$ip" "$port" >/dev/null 2>&1 || true
  elapsed=$(( ($(date +%s%N) - start) / 1000000 ))
  # Blocked (dropped) waits out the full timeout; allowed-but-refused
  # returns almost instantly. Half the timeout is a comfortable margin.
  if [ "$elapsed" -ge $(( TIMEOUT * 1000 / 2 )) ]; then
    actual="BLOCKED"
  else
    actual="ALLOWED"
  fi
  if [ "$actual" = "$expect" ]; then
    echo "OK:   $desc -> $actual (${elapsed}ms)"
  else
    echo "FAIL: $desc -> $actual (${elapsed}ms), expected $expect"
    fail=1
  fi
}

fail=0
check attacker-standin "$NAMESPACE" "$CATALOG_IP" 8080 BLOCKED "attacker -> catalog (AC3: non-gateway pod reaching a service directly)"
check gateway-standin "$NAMESPACE" "$CATALOG_IP" 8080 ALLOWED "gateway -> catalog"
check booking-standin "$NAMESPACE" "$CATALOG_IP" 8080 ALLOWED "booking -> catalog (documented sync hop)"
check notification-standin "$NAMESPACE" "$CATALOG_IP" 8080 BLOCKED "notification -> catalog (not gateway, not booking)"
check attacker-standin "$NAMESPACE" "$GATEWAY_IP" 8080 BLOCKED "attacker -> gateway"
check ingress-nginx-standin ingress-nginx "$GATEWAY_IP" 8080 ALLOWED "ingress-nginx -> gateway"

exit $fail
