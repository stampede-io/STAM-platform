#!/usr/bin/env bash
# STAM-71 AC2: poison messages against the live consumers on compose-dev.
#
#  1. A record that deserializes but can't be applied (PaymentAuthorized for a
#     reservation that doesn't exist) on payments.events. Booking must retry it
#     with exponential backoff (1 s, 2 s, 4 s) and then route it to
#     payments.events.dlq.
#  2. A record that isn't JSON at all on reservations.events. This is STAM-452:
#     catalog and notification use a bare JsonDeserializer, so the record never
#     reaches the error handler and the partition stalls. The drill reports the
#     lag, then skips the record by resetting both groups' offsets, so the
#     stack is usable again afterwards.
#
# usage, from STAM-platform/:  bash tools/hardening/poison-message-drill.sh
set -euo pipefail
cd "$(dirname "$0")/../../compose-dev"
dc() { MSYS_NO_PATHCONV=1 docker compose "$@"; }
kafka() { dc exec -T kafka /opt/kafka/bin/"$@"; }
produce() { kafka kafka-console-producer.sh --bootstrap-server localhost:9092 --topic "$1" --property parse.key=true --property key.separator='|'; }
in_dlq() { kafka kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic "$1" --from-beginning --timeout-ms 6000 --property print.key=true 2>/dev/null | grep -c "$2" || true; }
group_col() { kafka kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --group "$1" 2>/dev/null | awk -v p="$2" -v c="$3" '$2=="reservations.events" && $3==p {print $c}'; }
lag() { group_col "$1" "$2" 6; }
committed() { group_col "$1" "$2" 4; }
# If the run is cut short mid-recovery, don't leave the consumers stopped.
trap 'dc start catalog notification >/dev/null 2>&1 || true' EXIT
uuid() { node -e 'console.log(crypto.randomUUID())'; }

echo "=== 1. deserializable poison on payments.events"
R=$(uuid); E=$(uuid); T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "$R|{\"eventId\":\"$E\",\"eventType\":\"PaymentAuthorized\",\"version\":1,\"occurredAt\":\"2026-01-01T00:00:00Z\",\"correlationId\":\"$E\",\"aggregateId\":\"$R\",\"payload\":\"{\\\"reservationId\\\":\\\"$R\\\",\\\"pspRef\\\":\\\"x\\\"}\"}" \
  | produce payments.events
sleep 15
dc logs booking --since "$T0" 2>/dev/null | grep -E "Record in retry|Received PaymentAuthorized for reservation=$R" \
  | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>s.trim().split('\n').forEach(l=>{const j=JSON.parse(l.slice(l.indexOf('{')));console.log('  '+j.timestamp.slice(11,23)+' '+j.message)}))"
d1=$(in_dlq payments.events.dlq "$R")
echo "in payments.events.dlq: $d1"

echo "=== 2. non-JSON poison on reservations.events (STAM-452)"
R2=$(uuid)
echo "$R2|not-json-at-all" | produce reservations.events
sleep 15
P=$(kafka kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic reservations.events --from-beginning --timeout-ms 6000 \
      --property print.key=true --property print.partition=true --property print.offset=true 2>/dev/null | grep "$R2" | head -1)
if [ -z "$P" ]; then echo "could not find the poison record on the topic; not touching any offsets"; exit 1; fi
PART=$(sed -E 's/.*Partition:([0-9]+).*/\1/' <<<"$P"); OFF=$(sed -E 's/.*Offset:([0-9]+).*/\1/' <<<"$P")
c_lag=$(lag catalog-availability-projector "$PART"); n_lag=$(lag notification-service "$PART")
loops=$(dc logs catalog --since 10s 2>/dev/null | grep -c 'Consumer exception' || true)
d2=$(in_dlq reservations.events.dlq "$R2")
echo "partition $PART offset $OFF: catalog lag $c_lag, notification lag $n_lag, catalog 'Consumer exception' lines in 10 s: $loops, in DLQ: $d2"

# Only move a group that is actually parked on the poison record. Resetting a
# group that already got past it would rewind it and replay later events.
stuck=()
for g in catalog-availability-projector notification-service; do
  [ "$(committed "$g" "$PART")" = "$OFF" ] && stuck+=("$g")
done
if [ ${#stuck[@]} -gt 0 ]; then
  echo ">>> recovering: skip offset $OFF on partition $PART for ${stuck[*]}"
  dc stop catalog notification >/dev/null 2>&1
  for g in "${stuck[@]}"; do
    kafka kafka-consumer-groups.sh --bootstrap-server localhost:9092 --group "$g" \
      --topic "reservations.events:$PART" --reset-offsets --to-offset $((OFF + 1)) --execute >/dev/null 2>&1
  done
  dc up -d --wait catalog notification >/dev/null 2>&1
fi
echo "after recovery: catalog lag $(lag catalog-availability-projector "$PART"), notification lag $(lag notification-service "$PART")"

echo "=== Result"
[ "$d1" -ge 1 ] && echo "1 PASS: retried with backoff, then dead-lettered" || echo "1 FAIL"
if [ "$d2" -ge 1 ] && [ "${c_lag:-1}" = 0 ]; then echo "2 PASS: dead-lettered, partition not blocked"
else echo "2 FINDING (STAM-452): partition $PART blocked until offsets were reset by hand"; fi
