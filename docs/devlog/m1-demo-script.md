# M1 Demo — 2-minute recording script

**Goal:** In under 2 minutes, show a recruiter that (a) contention doesn't oversell,
(b) the saga recovers from a crash, (c) the numbers back it up.

**Recording tool:** Any screen capture that produces MP4 (OBS, Loom, ScreenToGif for
GIF fallback). Target 1080p, 30 fps, audio optional but a voice-over helps a lot.

**Terminal layout:** three tmux/wezterm panes side-by-side, big font (18–20 pt).

- **Pane A** — `docker compose logs -f booking payment | jq -r '.message'` (streaming logs)
- **Pane B** — command runner (where you type)
- **Pane C** — split into two:
  - top: `psql -h localhost -p 5433 -U booking_user -d booking` (or docker exec if no host port) — live SQL
  - bottom: `docker compose ps` or the k6 run

---

## Beat sheet (target: 1:50)

### Beat 1 — Setup (0:00–0:15, 15 s)

> "STAMPEDE is a ticketing platform. Milestone 1 proves two invariants: no seat
> is ever sold twice, and a saga survives a `kill -9`. Both are demonstrated here
> against a real Compose stack."

Show: `docker compose ps` — all five services `Up (healthy)`.

### Beat 2 — Contention hammer (0:15–0:45, 30 s)

> "First, contention. 1,000 virtual users, 200 seats, everyone racing for the same pool."

Run: `bash load-tests/k6/run-flash-sale.sh`

While it runs, cut to the SQL pane and run **live** during the test:

```sql
SELECT show_id, seat_id, COUNT(*)
FROM reservation_seats
WHERE status IN ('HELD','CONFIRMED')
GROUP BY show_id, seat_id
HAVING COUNT(*) > 1;
```

> "Zero rows. Right now. Under peak load. The partial-unique-index rejects the second insert."

When k6 finishes, cut to the summary — call out the three thresholds:

- `http_req_failed`: **X %** (target < 1 %)
- `http_req_duration p99`: **Y ms** (target < 300 ms)
- `oversells`: **0** (target 0)

### Beat 3 — Saga crash recovery (0:45–1:25, 40 s)

> "Second, resilience. Start a booking, kill the process mid-saga, restart, watch it converge."

Commands (readable-speed):

```bash
# 1. hold a seat
RES=$(curl -s -X POST http://localhost:8082/api/v1/reservations \
  -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $(uuidgen)" \
  -d "{\"showId\":\"$SHOW\",\"userId\":\"$(uuidgen)\",\"seatIds\":[\"$SEAT\"]}" \
  | jq -r .reservationId)

# 2. submit payment — kicks off the saga
curl -X POST http://localhost:8082/api/v1/reservations/$RES/submit-payment

# 3. IMMEDIATELY kill booking mid-saga
docker compose kill -s KILL booking
```

Show the `saga_instances` row is `PAYMENT_REQUESTED` — hung.

```bash
docker compose start booking
```

Wait 5–10 seconds. Show the same row is now `COMPLETED`.

> "SagaRecoverySweep at boot, plus a scheduled sweep every 30 seconds, picked it up
> and drove it to completion. Nothing lost."

### Beat 4 — Numbers on the wall (1:25–1:50, 25 s)

Cut to `README.md` — the numbers table:

| Metric              | Threshold          | M1 result          |
|---------------------|--------------------|--------------------|
| VUs (peak)          | ≥ 1,000            | 1,000              |
| `http_req_failed`   | < 1 %              | X %                |
| `http_req_duration` p99 | < 300 ms       | Y ms               |
| **Oversells**       | **0**              | **0**              |

> "Numbers, invariant, recovery. Milestone 1. Link to full report in the README."

---

## Common recording mistakes to avoid

- **Don't zoom in and out** — pick one font size, stick with it.
- **Don't narrate every command** — say the invariant, then show it.
- **Don't edit out the k6 ramp-up** — it's boring but shows a real test, not a curated clip.
- **Don't record with a full desktop background** — clean terminal, blank wallpaper.

## After recording

1. Upload to unlisted YouTube (or Loom, or attach to GitHub release as MP4).
2. Paste the URL into `README.md` at the marker `*(link goes here after recording)*`.
3. Paste the URL into the [STAM-209](https://puliththewmika-dev.atlassian.net/browse/STAM-209) Jira comment before closing.
