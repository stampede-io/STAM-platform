#!/usr/bin/env bash
# STAM-71 AC2: broker-down drill on compose-dev, in two phases.
#
#  A. Kafka goes away mid-sale and booking stays up. Holds must keep succeeding
#     (the oversell guard and the outbox row are plain Postgres, CLAUDE.md §4.1,
#     §4.3), and every SeatsHeld event must reach reservations.events once
#     Kafka is back, with catalog's projection catching up.
#  B. Same outage, but booking is killed with SIGKILL before Kafka returns.
#     This probes whether "published" in the outbox means "acked by Kafka".
#
# usage, from STAM-platform/:  bash tools/hardening/broker-down-drill.sh
# needs the compose stack up, node 20+, and catalog's dev-profile test seed.
set -euo pipefail
cd "$(dirname "$0")/../../compose-dev"
# Git Bash: keep docker's container paths literal without breaking curl's /dev/null.
dc() { MSYS_NO_PATHCONV=1 docker compose "$@"; }
# Whatever happens, never leave the stack without its broker or booking.
trap 'dc start kafka booking >/dev/null 2>&1 || true' EXIT
set -a; . ./.env; set +a
ts() { date +%H:%M:%S; }
json() { node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const j=JSON.parse(s);console.log($1)})"; }

curl -s -X DELETE http://localhost:8081/api/test-seed >/dev/null
SHOW=$(curl -s -X POST http://localhost:8081/api/test-seed | json 'j.showId')
mapfile -t SEATS < <(curl -s "http://localhost:8081/api/v1/shows/$SHOW/seats" | json 'j.slice(0,16).map(x=>x.id).join("\n")')
TOKEN=$(cd ../tools/hardening && node -e 'import("./pkce-login.mjs").then(async m=>{const e="broker-"+Date.now()+"@stampede.test";await m.register(e,"Drill-Password-123");console.log((await m.login(e,"Drill-Password-123")).accessToken)})')

hold() {
  curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost:8085/api/v1/reservations \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -H "Idempotency-Key: $(node -e 'console.log(crypto.randomUUID())')" \
    -d "{\"showId\":\"$SHOW\",\"seatIds\":[\"$1\"]}"
}
on_topic() {   # how many of the given seat ids appear in a SeatsHeld event
  local dump; dump=$(dc exec -T kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 \
    --topic reservations.events --from-beginning --timeout-ms 8000 2>/dev/null | grep SeatsHeld || true)
  local n=0; for s in "$@"; do grep -q "$s" <<<"$dump" && n=$((n + 1)); done; echo $n
}
published_in_outbox() {   # outbox rows for these seats that claim published
  local list; list=$(printf "'%s'," "$@"); list=${list%,}
  dc exec -T booking-db psql -U "$BOOKING_DB_USER" -d "$BOOKING_DB_NAME" -tAc \
    "select count(*) from outbox o join reservation_seats rs on rs.reservation_id = o.aggregate_id
     where o.event_type = 'SeatsHeld' and o.published_at is not null and rs.seat_id::text in ($list)"
}
held_in_catalog() {
  curl -s "http://localhost:8081/api/v1/shows/$SHOW/seats" | json 'j.filter(x=>x.availability==="HELD").length'
}
wait_healthy() { for _ in $(seq 1 90); do dc ps "$1" | grep -q healthy && return; sleep 2; done; }

echo "=== Phase A: Kafka down, booking stays up"
A=("${SEATS[@]:0:8}")
echo "$(ts) >>> stop kafka"; dc stop kafka >/dev/null 2>&1
ok=0; for s in "${A[@]}"; do c=$(hold "$s"); [ "$c" = 201 ] && ok=$((ok + 1)); done
echo "$(ts) holds accepted with Kafka DOWN: $ok/${#A[@]}"
echo "$(ts) >>> start kafka"; dc start kafka >/dev/null 2>&1; wait_healthy kafka; sleep 15
a_topic=$(on_topic "${A[@]}"); a_held=$(held_in_catalog)
echo "$(ts) SeatsHeld events on the topic: $a_topic/${#A[@]}; catalog HELD: $a_held"

echo "=== Phase B: Kafka down, booking SIGKILLed before Kafka returns"
B=("${SEATS[@]:8:4}")
echo "$(ts) >>> stop kafka"; dc stop kafka >/dev/null 2>&1
okb=0; for s in "${B[@]}"; do c=$(hold "$s"); [ "$c" = 201 ] && okb=$((okb + 1)); done
# The dangerous window: OutboxPublisher calls kafkaTemplate.send() without
# waiting for the ack, then markPublished(). Whether send() returns at once
# (buffered) or blocks on broker metadata depends on producer state, so wait
# up to 30 s for the rows to be marked before pulling the plug.
for _ in $(seq 1 15); do [ "$(published_in_outbox "${B[@]}")" = "${#B[@]}" ] && break; sleep 2; done
marked=$(published_in_outbox "${B[@]}")
echo "$(ts) holds accepted with Kafka DOWN: $okb/${#B[@]}; outbox rows marked published while Kafka is DOWN: $marked"
echo "$(ts) >>> kill -9 booking (crash while Kafka is down)"; dc kill -s KILL booking >/dev/null 2>&1
echo "$(ts) >>> start kafka, start booking"; dc start kafka >/dev/null 2>&1; wait_healthy kafka
dc start booking >/dev/null 2>&1; wait_healthy booking; sleep 15
b_topic=$(on_topic "${B[@]}")
echo "$(ts) SeatsHeld events on the topic: $b_topic/${#B[@]}; outbox still says published: $(published_in_outbox "${B[@]}")"

echo "=== Result"
[ "$ok" = "${#A[@]}" ] && [ "$a_topic" = "${#A[@]}" ] && echo "A PASS: no hold refused, all events delivered after recovery" || echo "A FAIL"
if [ "$b_topic" = "${#B[@]}" ]; then echo "B PASS: events survived a crash during the outage"
else echo "B FINDING: $(( ${#B[@]} - b_topic )) event(s) lost although the outbox marks them published"; fi
