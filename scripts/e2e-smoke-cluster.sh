#!/usr/bin/env bash
# STAM-54 / STAM-327: the real happy path -- register, PKCE login, create a
# venue/event/show as an organizer, hold a seat as a user, pay, confirm --
# run against an actual deployed cluster (kind or k3s), not mocked. Assumes
# `kubectl port-forward svc/gateway -n apps 18085:8080` is already running
# (left as a separate step rather than backgrounded here, so failures in
# this script don't leave an orphaned port-forward behind).
#
# Usage: GATEWAY_URL=http://localhost:18085 bash scripts/e2e-smoke-cluster.sh
set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:18085}"
APPS_NAMESPACE="${APPS_NAMESPACE:-apps}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PY=python3
"$PY" --version >/dev/null 2>&1 || PY=python

pkce_pair() {
  "$PY" -c "
import base64, hashlib, secrets
v = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b'=').decode()
c = base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).rstrip(b'=').decode()
print(v); print(c)
"
}

json_field() {
  # json_field <field> reads JSON from stdin, prints that top-level field
  "$PY" -c "import json,sys; print(json.load(sys.stdin)['$1'])"
}

# login(email, password) -> prints an access_token to stdout
login() {
  local email="$1" password="$2"
  local jar="$WORKDIR/cookies-$RANDOM.txt"
  local pair; pair=$(pkce_pair)
  local verifier; verifier=$(echo "$pair" | sed -n 1p)
  local challenge; challenge=$(echo "$pair" | sed -n 2p)

  curl -s -c "$jar" -b "$jar" -o /dev/null \
    "$GATEWAY_URL/oauth2/authorize?response_type=code&client_id=stampede-spa&redirect_uri=http%3A%2F%2Flocalhost%3A3000%2Fcallback&scope=openid%20profile%20email%20offline_access&code_challenge=$challenge&code_challenge_method=S256"

  local h2="$WORKDIR/h2-$RANDOM.txt"
  curl -s -c "$jar" -b "$jar" -D "$h2" -o /dev/null \
    -X POST "$GATEWAY_URL/login" \
    --data-urlencode "username=$email" --data-urlencode "password=$password"
  local loc; loc=$(grep -i '^Location:' "$h2" | sed 's/Location: //I' | tr -d '\r')

  local h3="$WORKDIR/h3-$RANDOM.txt"
  curl -s -c "$jar" -b "$jar" -D "$h3" -o /dev/null "$loc"
  local code; code=$(grep -i '^Location:' "$h3" | sed -n 's/.*code=\(.*\)/\1/p' | tr -d '\r')

  curl -s -X POST "$GATEWAY_URL/api/v1/oauth2/token" \
    --data-urlencode "grant_type=authorization_code" \
    --data-urlencode "code=$code" \
    --data-urlencode "redirect_uri=http://localhost:3000/callback" \
    --data-urlencode "client_id=stampede-spa" \
    --data-urlencode "code_verifier=$verifier" \
  | json_field access_token
}

echo "== register organizer =="
ORG_EMAIL="smoke-organizer-$(date +%s)@stampede.local"
curl -s -X POST "$GATEWAY_URL/api/v1/users/register" -H "Content-Type: application/json" \
  -d "{\"email\":\"$ORG_EMAIL\",\"password\":\"Passw0rd!\",\"role\":\"ORGANIZER\"}" >/dev/null
# Self-registration always grants USER regardless of the requested role
# (correct -- an unauthenticated caller shouldn't be able to grant itself
# ORGANIZER). Production promotes via an ADMIN PUT /users/{id}/role; this
# smoke script promotes directly in the DB since there's no seeded ADMIN
# account to call that endpoint with.
kubectl exec -n "$APPS_NAMESPACE" postgres-0 -- psql -U postgres -d identity_db -c \
  "UPDATE users SET role='ORGANIZER' WHERE email='$ORG_EMAIL';" >/dev/null
echo "  registered + promoted $ORG_EMAIL"

echo "== login organizer =="
ORG_TOKEN=$(login "$ORG_EMAIL" "Passw0rd!")

echo "== create venue/event/show =="
VENUE_ID=$(curl -s -X POST "$GATEWAY_URL/api/v1/venues" -H "Authorization: Bearer $ORG_TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"Smoke Arena","address":"1 Smoke St","capacity":10}' | json_field id)

EVENT_ID=$(curl -s -X POST "$GATEWAY_URL/api/v1/events" -H "Authorization: Bearer $ORG_TOKEN" -H "Content-Type: application/json" \
  -d "{\"venueId\":\"$VENUE_ID\",\"name\":\"Smoke Concert\",\"description\":\"e2e smoke\"}" | json_field id)

STARTS=$("$PY" -c "from datetime import datetime,timedelta,timezone;print((datetime.now(timezone.utc)+timedelta(days=1)).isoformat())")
ENDS=$("$PY" -c "from datetime import datetime,timedelta,timezone;print((datetime.now(timezone.utc)+timedelta(days=1,hours=2)).isoformat())")
SHOW_ID=$(curl -s -X POST "$GATEWAY_URL/api/v1/shows" -H "Authorization: Bearer $ORG_TOKEN" -H "Content-Type: application/json" \
  -d "{\"eventId\":\"$EVENT_ID\",\"startsAt\":\"$STARTS\",\"endsAt\":\"$ENDS\"}" | json_field id)
echo "  show=$SHOW_ID"

echo "== seed a seat directly (catalog has no seat-creation REST endpoint outside the demo DataLoader) =="
kubectl exec -n "$APPS_NAMESPACE" postgres-0 -- psql -U catalog_user -d catalog_db -c \
  "INSERT INTO seats (id, show_id, section, row_label, seat_number, price_cents)
   VALUES (gen_random_uuid(), '$SHOW_ID', 'GA', 'A', 1, 5000);" >/dev/null
SEAT_ID=$(curl -s "$GATEWAY_URL/api/v1/shows/$SHOW_ID/seats" | "$PY" -c "import json,sys;print(json.load(sys.stdin)[0]['id'])")
echo "  seat=$SEAT_ID"

echo "== register + login user =="
USER_EMAIL="smoke-user-$(date +%s)@stampede.local"
curl -s -X POST "$GATEWAY_URL/api/v1/users/register" -H "Content-Type: application/json" \
  -d "{\"email\":\"$USER_EMAIL\",\"password\":\"Passw0rd!\",\"role\":\"USER\"}" >/dev/null
USER_TOKEN=$(login "$USER_EMAIL" "Passw0rd!")

echo "== hold =="
IDEMKEY=$("$PY" -c "import uuid;print(uuid.uuid4())")
RES_ID=$(curl -s -X POST "$GATEWAY_URL/api/v1/reservations" \
  -H "Authorization: Bearer $USER_TOKEN" -H "Content-Type: application/json" -H "Idempotency-Key: $IDEMKEY" \
  -d "{\"showId\":\"$SHOW_ID\",\"seatIds\":[\"$SEAT_ID\"]}" | json_field reservationId)
echo "  reservation=$RES_ID"

echo "== set payment method + submit payment =="
curl -s -X PATCH "$GATEWAY_URL/api/v1/reservations/$RES_ID/payment-method" \
  -H "Authorization: Bearer $USER_TOKEN" -H "Content-Type: application/json" \
  -d '{"paymentMethodId":"pm_card_visa"}' >/dev/null
curl -s -X POST "$GATEWAY_URL/api/v1/reservations/$RES_ID/submit-payment" \
  -H "Authorization: Bearer $USER_TOKEN" >/dev/null

echo "== poll for CONFIRMED (saga runs async over Kafka) =="
STATUS="PENDING"
for i in $(seq 1 10); do
  STATUS=$(curl -s "$GATEWAY_URL/api/v1/reservations/$RES_ID" -H "Authorization: Bearer $USER_TOKEN" | json_field status)
  echo "  attempt $i: $STATUS"
  [ "$STATUS" = "CONFIRMED" ] && break
  sleep 1
done

if [ "$STATUS" = "CONFIRMED" ]; then
  echo "PASS: full saga confirmed end to end"
  exit 0
else
  echo "FAIL: reservation never reached CONFIRMED (status=$STATUS)"
  exit 1
fi
