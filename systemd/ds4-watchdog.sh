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
