#!/usr/bin/env bash
# Thin wrapper: run the recipe preflight, fail the unit if it fails.
set -euo pipefail
cd /home/sakkout/ds4-0731-recipe
set -a; source .env.dspark; set +a
exec bash scripts/ds4-preflight.sh
