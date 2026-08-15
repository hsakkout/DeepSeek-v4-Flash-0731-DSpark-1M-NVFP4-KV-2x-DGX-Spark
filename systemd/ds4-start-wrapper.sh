#!/usr/bin/env bash
# DS4 DSpark systemd wrapper — worker-first startup, then head.
# systemd calls this via ExecStart; it does NOT manage the containers itself
# (docker-compose does). This wrapper just sequences the orchestration.
set -euo pipefail

RECIPE=/home/sakkout/ds4-0731-recipe
LOGTAG="ds4-dspark"

log() { echo "[${LOGTAG}] $*"; logger -t "${LOGTAG}" "$*" 2>/dev/null || true; }

log "starting DS4 worker-first sequence..."
# The recipe's start script already does worker (NODE_RANK=1) then head (NODE_RANK=0),
# scp's compose+env to the worker, and polls /v1/models until healthy.
cd "$RECIPE"
./start-deepseek-v4-flash-dspark.sh
log "DS4 start sequence complete (head healthy on :8888)"
