#!/usr/bin/env bash
# Post-k6 oversell verification against the booking database.
# Usage: ./verify-oversells.sh [DB_HOST] [DB_PORT] [DB_USER] [DB_NAME]

DB_HOST="${1:-localhost}"
DB_PORT="${2:-5432}"
DB_USER="${3:-booking}"
DB_NAME="${4:-booking}"

echo "=== Oversell verification ==="
echo "Checking ${DB_HOST}:${DB_PORT}/${DB_NAME} as ${DB_USER} ..."

RESULT=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A -c \
  "SELECT COUNT(*) FROM (
     SELECT show_id, seat_id, COUNT(*) AS cnt
     FROM reservation_seats
     WHERE status IN ('HELD', 'CONFIRMED')
     GROUP BY show_id, seat_id
     HAVING COUNT(*) > 1
   ) oversold;")

if [ "$RESULT" -eq 0 ]; then
  echo "PASS: 0 oversold seats."
  exit 0
else
  echo "FAIL: ${RESULT} oversold seat(s) detected!"
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c \
    "SELECT show_id, seat_id, COUNT(*) AS cnt
     FROM reservation_seats
     WHERE status IN ('HELD', 'CONFIRMED')
     GROUP BY show_id, seat_id
     HAVING COUNT(*) > 1;"
  exit 1
fi
