#!/usr/bin/env bash
# STAM-52 / STAM-317: proves AC2 live -- each service's Postgres user can
# connect to its own database and is denied CONNECT on every other one.
# Usage: bash scripts/verify-db-isolation.sh [namespace]
set -euo pipefail

NAMESPACE="${1:-apps}"

declare -A OWNER_DB=(
  [identity_user]=identity_db
  [catalog_user]=catalog_db
  [booking_user]=booking_db
  [payment_user]=payment_db
  [notification_user]=notification_db
)

fail=0
for user in "${!OWNER_DB[@]}"; do
  own_db="${OWNER_DB[$user]}"

  if kubectl exec -n "$NAMESPACE" postgres-0 -- psql -U "$user" -d "$own_db" -c "SELECT 1;" >/dev/null 2>&1; then
    echo "PASS: $user can connect to its own db ($own_db)"
  else
    echo "FAIL: $user could NOT connect to its own db ($own_db)"
    fail=1
  fi

  for other_db in "${OWNER_DB[@]}"; do
    [ "$other_db" = "$own_db" ] && continue
    if kubectl exec -n "$NAMESPACE" postgres-0 -- psql -U "$user" -d "$other_db" -c "SELECT 1;" >/dev/null 2>&1; then
      echo "FAIL: $user was able to connect to $other_db (should be denied)"
      fail=1
    fi
  done
  echo "  $user denied on every other database"
done

if [ "$fail" -eq 0 ]; then
  echo "PASS: database-per-service isolation holds for all 5 services"
  exit 0
else
  echo "FAIL: isolation violated (see above)"
  exit 1
fi
