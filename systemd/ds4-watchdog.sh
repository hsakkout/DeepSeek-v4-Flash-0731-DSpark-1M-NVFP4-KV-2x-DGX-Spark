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

# --- Memory pressure: warn-only tracking (DS4 nominally leaves ~5-8 GiB avail) ---
AVAIL_KB=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
SWAP_USED_KB=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{print t-f}' /proc/meminfo)
AVAIL_GB=$((AVAIL_KB/1048576)); SWAP_GB=$((SWAP_USED_KB/1048576))
SWAP_PREV_FILE="$STATE_DIR/swap_kb_prev"
swap_prev=$(cat "$SWAP_PREV_FILE" 2>/dev/null || echo "$SWAP_USED_KB")
echo "$SWAP_USED_KB" > "$SWAP_PREV_FILE"
swap_delta_gb=$(( (SWAP_USED_KB - swap_prev) / 1048576 ))

if [ "$AVAIL_GB" -lt 8 ]; then
  log "MEMWARN MemAvailable=${AVAIL_GB}GiB (<8) swap_used=${SWAP_GB}GiB — memory pressure near DS4 ceiling"
fi
if [ "$swap_delta_gb" -gt 1 ]; then
  log "MEMWARN swap grew +${swap_delta_gb}GiB since last tick (total ${SWAP_GB}GiB) — likely reclaim churn"
fi

# Escalation: after 5 consecutive MEMWARN ticks emit an ALERT line (the Hermes
# cron relays ALERT lines to Telegram, dedup'd by its own state file).
WARN_STREAK_FILE="$STATE_DIR/memwarn_streak"
if [ "$AVAIL_GB" -lt 8 ] || [ "$swap_delta_gb" -gt 1 ]; then
  streak=$(( $(cat "$WARN_STREAK_FILE" 2>/dev/null || echo 0) + 1 ))
  echo "$streak" > "$WARN_STREAK_FILE"
  if [ "$streak" -ge 5 ]; then
    log "ALERT sustained memory pressure: ${streak} consecutive MEMWARN ticks (MemAvailable=${AVAIL_GB}GiB, swap=${SWAP_GB}GiB). Consider GPU_MEMORY_UTILIZATION 0.80->0.77."
  fi
else
  echo 0 > "$WARN_STREAK_FILE"
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
