#!/usr/bin/env bash
# STAM-71 AC2: kill -9 booking with a saga in flight, on compose-dev.
#
# Payment is stopped first, so the saga sits in PAYMENT_REQUESTED with its
# AuthorizePayment command on payments.commands and nobody answering. Booking
# is then SIGKILLed, and payment comes back while booking is still dead, so
# its PaymentAuthorized reply waits on payments.events. When booking restarts,
# the saga must resume from Postgres and the Kafka log alone: saga COMPLETED,
# reservation CONFIRMED, exactly one saga row.
#
# usage, from STAM-platform/:  bash tools/hardening/saga-crash-drill.sh
# needs the compose stack up with PAYMENT_GATEWAY=mock (the compose default)
# and PAYMENT_FAILURE_RATE=0.0, node 20+, and catalog's dev-profile test seed.
set -euo pipefail
cd "$(dirname "$0")/../../compose-dev"
dc() { MSYS_NO_PATHCONV=1 docker compose "$@"; }
trap 'dc start payment booking >/dev/null 2>&1 || true' EXIT
set -a; . ./.env; set +a
ts() { date +%H:%M:%S; }
json() { node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const j=JSON.parse(s);console.log($1)})"; }
sql() { dc exec -T booking-db psql -U "$BOOKING_DB_USER" -d "$BOOKING_DB_NAME" -tAc "$1"; }
wait_healthy() { for _ in $(seq 1 90); do dc ps "$1" | grep -q healthy && return; sleep 2; done; }
api() {   # method path [body]
  curl -s -X "$1" "http://localhost:8085$2" -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' -H "Idempotency-Key: $(node -e 'console.log(crypto.randomUUID())')" ${3:+-d "$3"}
}

curl -s -X DELETE http://localhost:8081/api/test-seed >/dev/null
SHOW=$(curl -s -X POST http://localhost:8081/api/test-seed | json 'j.showId')
SEAT=$(curl -s "http://localhost:8081/api/v1/shows/$SHOW/seats" | json 'j[0].id')
TOKEN=$(cd ../tools/hardening && node -e 'import("./pkce-login.mjs").then(async m=>{const e="saga-"+Date.now()+"@stampede.test";await m.register(e,"Drill-Password-123");console.log((await m.login(e,"Drill-Password-123")).accessToken)})')

RES=$(api POST /api/v1/reservations "{\"showId\":\"$SHOW\",\"seatIds\":[\"$SEAT\"]}" | json 'j.reservationId')
api PATCH "/api/v1/reservations/$RES/payment-method" '{"paymentMethodId":"pm_card_visa"}' >/dev/null
echo "$(ts) reservation $RES held, payment method set"

echo "$(ts) >>> stop payment"; dc stop payment >/dev/null 2>&1
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "http://localhost:8085/api/v1/reservations/$RES/submit-payment" -H "Authorization: Bearer $TOKEN")
echo "$(ts) submit-payment -> $code"
for _ in $(seq 1 15); do
  [ "$(sql "select count(*) from outbox where aggregate_id='$RES' and event_type='AuthorizePayment' and published_at is not null")" = 1 ] && break; sleep 1
done
echo "$(ts) before crash: saga $(sql "select state||'/'||step from saga_instances where reservation_id='$RES'"), AuthorizePayment acked by Kafka: $(sql "select count(*) from outbox where aggregate_id='$RES' and event_type='AuthorizePayment' and published_at is not null")"

echo "$(ts) >>> kill -9 booking (saga in flight)"; dc kill -s KILL booking >/dev/null 2>&1
echo "$(ts) >>> start payment while booking is dead"; dc start payment >/dev/null 2>&1; wait_healthy payment; sleep 10
echo "$(ts) >>> start booking"; dc start booking >/dev/null 2>&1; wait_healthy booking

for _ in $(seq 1 30); do
  [ "$(sql "select state from saga_instances where reservation_id='$RES'")" = COMPLETED ] && break; sleep 2
done
saga=$(sql "select state||'/'||step from saga_instances where reservation_id='$RES'")
sagas=$(sql "select count(*) from saga_instances where reservation_id='$RES'")
status=$(api GET "/api/v1/reservations/$RES" | json 'j.status')
echo "$(ts) after restart: saga $saga (rows: $sagas); reservation $status"

echo "=== Result"
if [[ "$saga" == COMPLETED/* && "$sagas" = 1 && "$status" = CONFIRMED ]]; then
  echo "PASS: the saga resumed after kill -9 and confirmed the reservation"
else
  echo "FAIL"; exit 1
fi
