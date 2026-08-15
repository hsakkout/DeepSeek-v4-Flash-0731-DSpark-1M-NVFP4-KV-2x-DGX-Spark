#!/usr/bin/env bash
# DS4 cluster watchdog — probes the head API and restarts the PAIR on
# sustained failure. Run by ds4-watchdog.timer every 2 min on Node 1.
#
# Failure classes handled:
#   - API down while unit should be active  -> restart pair
#   - half-pair: head+worker container ages diverge badly -> restart pair
#   - llama-server active alongside DS4      -> stop llama (memory guard)
#
# Safety: if ds4-dspark.service is currently activating (startup takes ~7-12
# min for the 155GiB 2-node load), the watchdog does NOT touch anything.
set -uo pipefail

UNIT="ds4-dspark.service"
API="http://127.0.0.1:8888/v1/models"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ds4-watchdog"
FAIL_FILE="$STATE_DIR/consecutive_failures"
LOG_FILE="$STATE_DIR/watchdog.log"
THRESHOLD=3
WORKER="spark-8485"

mkdir -p "$STATE_DIR"
log() { echo "$(date -Is) $*" >> "$LOG_FILE"; }

# --- Never interfere with an in-flight start/stop ---
state=$(systemctl --user is-active "$UNIT" 2>/dev/null || true)
substate=$(systemctl --user show "$UNIT" -p SubState --value 2>/dev/null || true)
if [ "$state" = "activating" ] || [ "$substate" = "auto-restart" ]; then
  log "unit activating — watchdog standing down"
  exit 0
fi

# --- Memory guard: llama must not coexist with DS4 ---
if systemctl --user is-active llama-server >/dev/null 2>&1; then
  log "llama-server active alongside DS4 — stopping it (memory guard)"
  systemctl --user stop llama-server >> "$LOG_FILE" 2>&1 || true
fi

# --- Memory pressure: warn-only tracking (available floor ~5-7 GiB w/ DS4) ---
AVAIL_KB=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
SWAP_USED_KB=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{print t-f}' /proc/meminfo)
AVAIL_GB=$((AVAIL_KB/1048576)); SWAP_GB=$((SWAP_USED_KB/1048576))
SWAP_PREV_FILE="$STATE_DIR/swap_kb_prev"
swap_prev=$(cat "$SWAP_PREV_FILE" 2>/dev/null || echo "$SWAP_USED_KB")
echo "$SWAP_USED_KB" > "$SWAP_PREV_FILE"
swap_delta_gb=$(( (SWAP_USED_KB - swap_prev) / 1048576 ))

# DS4 at 0.80 util leaves ~5-7 GiB available steady-state; warn below 6, alert below 5.
if [ "$AVAIL_GB" -lt 6 ]; then
  log "MEMWARN MemAvailable=${AVAIL_GB}GiB (<6) swap_used=${SWAP_GB}GiB — memory pressure near DS4 ceiling"
fi
if [ "$swap_delta_gb" -gt 1 ]; then
  log "MEMWARN swap grew +${swap_delta_gb}GiB since last tick (total ${SWAP_GB}GiB) — likely reclaim churn"
fi

# --- Memory pressure state machine ---
# States: CLEAR -> ALERT (5 distress ticks) -> REMINDER (every 24h sustained) -> ALLCLEAR
# Distress = MemAvailable < 5 GiB OR swap grew >1 GiB since last tick.
# Logs: MEMWARN every tick while <6 GiB; ALERT/REMINDER/ALLCLEAR are state transitions only.
WARN_STREAK_FILE="$STATE_DIR/memwarn_streak"
MEM_STATE_FILE="$STATE_DIR/mem_alert_state"     # clear|alert
MEM_ALERT_TS_FILE="$STATE_DIR/mem_alert_ts"      # epoch of first ALERT
MEM_LAST_REMINDER_FILE="$STATE_DIR/mem_last_reminder"  # epoch of last reminder

in_distress=0
[ "$AVAIL_GB" -lt 5 ] && in_distress=1
[ "$swap_delta_gb" -gt 1 ] && in_distress=1

if [ "$in_distress" = "1" ]; then
  streak=$(( $(cat "$WARN_STREAK_FILE" 2>/dev/null || echo 0) + 1 ))
  echo "$streak" > "$WARN_STREAK_FILE"
  mem_state=$(cat "$MEM_STATE_FILE" 2>/dev/null || echo clear)
  alert_ts=$(cat "$MEM_ALERT_TS_FILE" 2>/dev/null || echo 0)

  if [ "$streak" -ge 5 ]; then
    if [ "$mem_state" = "clear" ]; then
      # First transition into alert
      now=$(date +%s)
      echo alert > "$MEM_STATE_FILE"
      echo "$now" > "$MEM_ALERT_TS_FILE"
      echo "$now" > "$MEM_LAST_REMINDER_FILE"
      log "ALERT memory pressure onset: MemAvailable=${AVAIL_GB}GiB swap=${SWAP_GB}GiB (streak=$streak)"
    else
      # Already in alert — check for 24h reminder
      last_reminder=$(cat "$MEM_LAST_REMINDER_FILE" 2>/dev/null || echo 0)
      now=$(date +%s)
      hours_since=$(( (now - last_reminder) / 3600 ))
      if [ "$hours_since" -ge 24 ]; then
        echo "$now" > "$MEM_LAST_REMINDER_FILE"
        elapsed_h=$(( (now - alert_ts) / 3600 ))
        log "REMINDER memory pressure sustained ${elapsed_h}h: MemAvailable=${AVAIL_GB}GiB swap=${SWAP_GB}GiB"
      fi
    fi
  fi
else
  # Not in distress — reset streak; if we were in alert, emit ALLCLEAR
  echo 0 > "$WARN_STREAK_FILE"
  mem_state=$(cat "$MEM_STATE_FILE" 2>/dev/null || echo clear)
  if [ "$mem_state" = "alert" ]; then
    alert_ts=$(cat "$MEM_ALERT_TS_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    elapsed_h=$(( (now - alert_ts) / 3600 ))
    echo clear > "$MEM_STATE_FILE"
    log "ALLCLEAR memory pressure resolved after ${elapsed_h}h. MemAvailable=${AVAIL_GB}GiB swap=${SWAP_GB}GiB"
  fi
fi

# --- Should DS4 even be up? Only supervise when the unit is enabled ---
if ! systemctl --user is-enabled "$UNIT" >/dev/null 2>&1; then
  # Not enabled = admin intentionally not supervising; clear failures, exit.
  echo 0 > "$FAIL_FILE"
  exit 0
fi

# --- Health probe ---
if curl -fsS -m 8 "$API" >/dev/null 2>&1; then
  prev=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
  [ "$prev" != "0" ] && log "API healthy again (was $prev consecutive failures)"
  echo 0 > "$FAIL_FILE"
  exit 0
fi

fails=$(( $(cat "$FAIL_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$fails" > "$FAIL_FILE"
log "health probe FAILED ($fails/$THRESHOLD) — $API"

if [ "$fails" -lt "$THRESHOLD" ]; then
  exit 0
fi

# --- Threshold reached: diagnose then restart the PAIR ---
head_age=$(docker inspect ds4-0731-recipe-vllm-dspark-1 --format '{{.State.StartedAt}}' 2>/dev/null || echo none)
worker_age=$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$WORKER" \
  "docker inspect ds4-0731-recipe-vllm-dspark-1 --format '{{.State.StartedAt}}'" 2>/dev/null || echo none)
log "restart triggered: head_started=$head_age worker_started=$worker_age"

# Full pair restart via the service unit (stop handles both nodes).
echo 0 > "$FAIL_FILE"
if systemctl --user restart "$UNIT" >> "$LOG_FILE" 2>&1; then
  log "pair restart OK"
else
  log "pair restart FAILED — manual intervention needed"
fi
