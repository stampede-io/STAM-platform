#!/usr/bin/env bash
# STAM-206 · Run the flash-sale k6 test against the local compose stack.
# Discovers an active show + its seat IDs from the catalog API, then runs k6.
#
# Usage:
#   ./run-flash-sale.sh                       # default urls
#   BOOKING_URL=... CATALOG_URL=... ./run-flash-sale.sh
#
# Environment overrides (optional):
#   SHOW_ID          - use a specific show (default: first from GET /shows)
#   CONFIRM_TIMEOUT_MS  - saga convergence timeout per VU (default 5000)
#
# Produces:
#   ../results/flash-sale-<utc-date>-<sha>.json  (k6 --summary-export)
#   ../results/flash-sale-<utc-date>-<sha>.txt   (k6 stdout)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$(cd "$SCRIPT_DIR/../results" && pwd)"

BOOKING_URL="${BOOKING_URL:-http://localhost:8082}"
CATALOG_URL="${CATALOG_URL:-http://localhost:8081}"

echo "=== Flash-sale runner ==="
echo "booking : $BOOKING_URL"
echo "catalog : $CATALOG_URL"

# Wait for services to be up.
for url in "$CATALOG_URL/actuator/health" "$BOOKING_URL/actuator/health"; do
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

# Discover show id.
if [ -z "${SHOW_ID:-}" ]; then
  SHOW_ID=$(curl -s "$CATALOG_URL/api/v1/shows?limit=1" | grep -oE '"id":"[a-f0-9-]{36}"' | head -1 | cut -d'"' -f4)
  if [ -z "$SHOW_ID" ]; then
    echo "FAIL: no shows in catalog. Start compose with the 'dev' spring profile to load seed data."
    exit 1
  fi
fi
echo "show id : $SHOW_ID"

# Discover seat ids for that show.
SEAT_IDS=$(curl -s "$CATALOG_URL/api/v1/shows/$SHOW_ID/seats" \
  | grep -oE '"id":"[a-f0-9-]{36}"' | cut -d'"' -f4 | paste -sd, -)
if [ -z "$SEAT_IDS" ]; then
  echo "FAIL: no seats found for show $SHOW_ID"
  exit 1
fi
SEAT_COUNT=$(echo "$SEAT_IDS" | tr ',' '\n' | wc -l | tr -d ' ')
echo "seats   : $SEAT_COUNT"

# Git SHA for report naming.
SHA=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "nogit")
STAMP=$(date -u +%Y%m%d)

SUMMARY_JSON="$RESULTS_DIR/flash-sale-${STAMP}-${SHA}.json"
STDOUT_TXT="$RESULTS_DIR/flash-sale-${STAMP}-${SHA}.txt"

echo "results : $SUMMARY_JSON"

BOOKING_URL="$BOOKING_URL" CATALOG_URL="$CATALOG_URL" \
SHOW_ID="$SHOW_ID" SEAT_IDS="$SEAT_IDS" \
CONFIRM_TIMEOUT_MS="${CONFIRM_TIMEOUT_MS:-5000}" \
k6 run \
  --summary-export "$SUMMARY_JSON" \
  "$SCRIPT_DIR/flash-sale.js" | tee "$STDOUT_TXT"

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
