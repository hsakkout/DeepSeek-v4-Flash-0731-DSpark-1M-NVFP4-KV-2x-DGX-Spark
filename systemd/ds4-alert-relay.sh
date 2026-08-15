#!/usr/bin/env bash
# Relay new ALERT lines from the DS4 watchdog log to the job's stdout.
# Intended as a no_agent cron script: stdout becomes the delivered message.
# Tracks last-reported byte offset so each ALERT is sent exactly once.
set -uo pipefail

LOG="${XDG_STATE_HOME:-$HOME/.local/state}/ds4-watchdog/watchdog.log"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/ds4-watchdog/alert_relay_offset"

[ -f "$LOG" ] || exit 0

offset=$(cat "$STATE" 2>/dev/null || echo 0)
size=$(stat -c %s "$LOG")

# Log rotated/truncated? Restart from the tail we have.
if [ "$size" -lt "$offset" ]; then offset=0; fi

new=$(tail -c +$((offset+1)) "$LOG")
echo "$size" > "$STATE"

alerts=$(printf '%s\n' "$new" | grep ' ALERT ' || true)
[ -n "$alerts" ] || exit 0   # empty stdout = silent (no delivery)

printf '⚠️ DS4 memory alert (promaxgb10-0874):\n\n%s\n' "$alerts"
