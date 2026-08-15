#!/usr/bin/env bash
# DS4 DSpark systemd stop wrapper — stop head + worker via recipe script.
set -euo pipefail
RECIPE=/home/sakkout/ds4-0731-recipe
cd "$RECIPE"
./stop-deepseek-v4-flash-dspark.sh
