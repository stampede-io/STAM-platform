#!/usr/bin/env bash
# AC2 smoke test: each service's role can connect to its own database and
# nothing else. Run after `helm install` (needs the postgres pod up and the
# post-install init Job to have run). Exits non-zero on the first violation.
set -euo pipefail

DATABASES=(identity_db catalog_db booking_db payment_db notification_db)
USERS=(identity_user catalog_user booking_user payment_user notification_user)
PASSWORD="changeme" # matches values.yaml's kind-local default

POD=$(kubectl get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')

fail=0
for i in "${!USERS[@]}"; do
  user="${USERS[$i]}"
  own_db="${DATABASES[$i]}"
  for db in "${DATABASES[@]}"; do
    if kubectl exec "$POD" -- env PGPASSWORD="$PASSWORD" psql -U "$user" -d "$db" -h localhost -c "SELECT 1" >/dev/null 2>&1; then
      result="CONNECTED"
    else
      result="DENIED"
    fi
    if [ "$db" = "$own_db" ]; then
      if [ "$result" != "CONNECTED" ]; then
        echo "FAIL: $user could not connect to its own database $db (expected CONNECTED, got $result)"
        fail=1
      else
        echo "OK:   $user -> $db: $result (expected)"
      fi
    else
      if [ "$result" != "DENIED" ]; then
        echo "FAIL: $user connected to $db, which is not its own database (expected DENIED, got $result) — AC2 violated"
        fail=1
      else
        echo "OK:   $user -> $db: $result (expected)"
      fi
    fi
  done
done

exit $fail
