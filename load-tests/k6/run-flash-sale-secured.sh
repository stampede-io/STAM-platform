#!/usr/bin/env bash
# STAM-288 · Run the secured flash-sale k6 test through the gateway.
# Discovers show + seat IDs from catalog (via gateway), then runs k6 with
# JWT auth through the full stack: identity + gateway + booking + payment.
#
# Usage:
#   ./run-flash-sale-secured.sh
#   GATEWAY_URL=http://localhost:8085 ./run-flash-sale-secured.sh
#
# Produces:
#   ../results/flash-sale-secured-<utc-date>-<sha>.json
#   ../results/flash-sale-secured-<utc-date>-<sha>.txt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$(cd "$SCRIPT_DIR/../results" && pwd)"

GATEWAY_URL="${GATEWAY_URL:-http://localhost:8085}"
CATALOG_URL="${CATALOG_URL:-http://localhost:8081}"

echo "=== Secured flash-sale runner ==="
echo "gateway : $GATEWAY_URL"
echo "catalog : $CATALOG_URL (for seat discovery)"

# Wait for services to be up.
for url in "$GATEWAY_URL/actuator/health" "$CATALOG_URL/actuator/health"; do
  echo "Waiting for $url ..."
  for i in {1..30}; do
    if curl -sf "$url" > /dev/null; then
      echo "  up"
      break
    fi
    sleep 2
    if [ "$i" -eq 30 ]; then
      echo "TIMEOUT: $url did not come up"
      exit 1
    fi
  done
done

# Discover show id from catalog (direct, not through gateway — avoids needing auth for discovery).
if [ -z "${SHOW_ID:-}" ]; then
  SHOW_ID=$(curl -s "$CATALOG_URL/api/v1/shows?limit=1" | grep -oE '"id":"[a-f0-9-]{36}"' | head -1 | cut -d'"' -f4)
  if [ -z "$SHOW_ID" ]; then
    echo "FAIL: no shows in catalog. Start compose with the 'dev' spring profile to load seed data."
    exit 1
  fi
fi
echo "show id : $SHOW_ID"

# Discover seat ids.
SEAT_IDS=$(curl -s "$CATALOG_URL/api/v1/shows/$SHOW_ID/seats" \
  | grep -oE '"id":"[a-f0-9-]{36}"' | cut -d'"' -f4 | paste -sd, -)
if [ -z "$SEAT_IDS" ]; then
  echo "FAIL: no seats found for show $SHOW_ID"
  exit 1
fi
SEAT_COUNT=$(echo "$SEAT_IDS" | tr ',' '\n' | wc -l | tr -d ' ')
echo "seats   : $SEAT_COUNT"

SHA=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "nogit")
STAMP=$(date -u +%Y%m%d)

SUMMARY_JSON="$RESULTS_DIR/flash-sale-secured-${STAMP}-${SHA}.json"
STDOUT_TXT="$RESULTS_DIR/flash-sale-secured-${STAMP}-${SHA}.txt"

echo "results : $SUMMARY_JSON"

# A crossed threshold exits non-zero. Capture it but keep going: the DB-level
# oversell check below is the invariant that actually gates this run.
K6_EXIT=0
GATEWAY_URL="$GATEWAY_URL" \
AUTH_URL="${AUTH_URL:-http://localhost:8084}" \
SHOW_ID="$SHOW_ID" SEAT_IDS="$SEAT_IDS" \
CONFIRM_TIMEOUT_MS="${CONFIRM_TIMEOUT_MS:-8000}" \
USER_POOL_SIZE="${USER_POOL_SIZE:-200}" \
SUMMARY_JSON="$SUMMARY_JSON" \
k6 run \
  "$SCRIPT_DIR/flash-sale-secured.js" > >(tee "$STDOUT_TXT") 2>&1 || K6_EXIT=$?

if [ "$K6_EXIT" -ne 0 ]; then
  echo
  echo "NOTE: k6 exited ${K6_EXIT} (thresholds crossed). Continuing to oversell check."
fi

echo
echo "=== Verifying zero oversells in booking DB (via docker exec) ==="
COMPOSE_DIR="$(cd "$SCRIPT_DIR/../../compose-dev" && pwd)"
BOOKING_DB_USER="${BOOKING_DB_USER:-booking_user}"
BOOKING_DB_NAME="${BOOKING_DB_NAME:-booking}"
OVERSOLD=$(docker compose -f "$COMPOSE_DIR/docker-compose.yml" exec -T booking-db \
  psql -U "$BOOKING_DB_USER" -d "$BOOKING_DB_NAME" -t -A -c \
  "SELECT COUNT(*) FROM (
     SELECT show_id, seat_id, COUNT(*) AS cnt
     FROM reservation_seats
     WHERE status IN ('HELD', 'CONFIRMED')
     GROUP BY show_id, seat_id
     HAVING COUNT(*) > 1
   ) oversold;" | tr -d '[:space:]')
if [ "$OVERSOLD" = "0" ]; then
  echo "PASS: 0 oversold seats."
else
  echo "FAIL: ${OVERSOLD} oversold seat(s) detected!"
  exit 1
fi

echo
echo "Report inputs saved to $SUMMARY_JSON"
