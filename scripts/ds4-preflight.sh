#!/usr/bin/env bash
# DS4 DSpark preflight — catches the recipe's known gotchas BEFORE launch.
# Run on Node 1 (head). Checks both Node 1 and Node 2.
set -uo pipefail
PASS=0; WARN=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  OK   $*"; }
warn() { WARN=$((WARN+1)); echo "  WARN $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $*"; }

WORKER="${WORKER_HOST:-spark-8485}"
HF_CACHE="${HF_CACHE:-$HOME/.cache/huggingface}"

echo "== DS4 preflight (Node 1 head, worker=$WORKER) =="

# --- HF cache ownership (both nodes) ---
if [ "$(stat -c '%U' "$HF_CACHE" 2>/dev/null)" = "$(whoami)" ]; then ok "HF cache owned by $(whoami) (head)"
else bad "HF cache NOT owned by $(whoami) on head — run: sudo chown -R $(whoami):$(whoami) $HF_CACHE"; fi

if ssh -o ConnectTimeout=8 -o BatchMode=yes "$WORKER" "[ \"\$(stat -c '%U' \$HOME/.cache/huggingface 2>/dev/null)\" = \"\$(whoami)\" ]" 2>/dev/null; then
  ok "HF cache owned by $(whoami) (worker)"; else bad "HF cache NOT owned by $(whoami) on worker — run on worker: sudo chown -R sakkout:sakkout ~/.cache/huggingface"; fi

# --- docker compose + no-sudo (both nodes) ---
docker compose version >/dev/null 2>&1 && ok "docker compose present (head)" || bad "docker compose missing (head)"
docker info >/dev/null 2>&1 && ok "docker no-sudo works (head)" || bad "docker requires sudo (head)"
ssh -o ConnectTimeout=8 -o BatchMode=yes "$WORKER" "docker compose version" >/dev/null 2>&1 && ok "docker compose present (worker)" || bad "docker compose missing (worker)"
ssh -o ConnectTimeout=8 -o BatchMode=yes "$WORKER" "docker info" >/dev/null 2>&1 && ok "docker no-sudo works (worker)" || bad "docker requires sudo (worker)"

# --- RDMA: a valid RoCEv2 GID must exist on all 4 devices (both nodes) ---
# The GID index is NOT stable across reboots/driver reloads: the table can
# shift (e.g. RoCEv2 moved 3->4 on spark-8485 after an Aug-2026 driver event).
# So probe each device for the lowest index whose type is "RoCE v2" and a
# non-zero GID, instead of hard-coding index 3.
for host in self "$WORKER"; do
  cmd='for d in rocep1s0f0 rocep1s0f1 roceP2p1s0f0 roceP2p1s0f1; do
    found=""
    for i in 0 1 2 3 4 5 6 7; do
      t=$(cat /sys/class/infiniband/$d/ports/1/gid_attrs/types/$i 2>/dev/null)
      g=$(cat /sys/class/infiniband/$d/ports/1/gids/$i 2>/dev/null)
      # want global (IPv6-mapped) RoCEv2 GIDs, not fe80 link-local ones
      case "$g" in fe80*|"") continue ;; esac
      if [ "$t" = "RoCE v2" ]; then found=$i; break; fi
    done
    if [ -n "$found" ]; then echo "ok $d gid$found"; else echo "bad $d"; fi
  done'
  if [ "$host" = self ]; then out=$(bash -c "$cmd"); else out=$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$host" "$cmd" 2>/dev/null); fi
  good=$(echo "$out" | grep -c '^ok' || true); total=$(echo "$out" | grep -c '^' || true)
  if [ "$good" = "4" ]; then ok "RoCEv2 GID present 4/4 ($host): $(echo "$out" | awk '{printf "%s:%s ", $2, $3}' | tr -d '\n')"
  else bad "RoCEv2 GID missing on $((4-good)) device(s) ($host): $out"; fi
done

# --- Interfaces UP (both nodes) ---
if ip -br addr show | grep -qE 'enp1s0f1np1\s+UP'; then ok "socket iface enp1s0f1np1 UP (head)"; else bad "enp1s0f1np1 DOWN (head)"; fi

# --- Ports free: 8888, 25000, 29501 ---
for p in 8888 25000 29501; do
  ss -tln 2>/dev/null | grep -q ":$p " && bad "port $p IN USE (head)" || ok "port $p free (head)"
done

# --- Image present (both nodes) ---
IMG="vllm-dspark-runtime:dspark-nvfp4-stage-c"
docker image inspect "$IMG" >/dev/null 2>&1 && ok "image $IMG (head)" || warn "image $IMG missing (head) — build pending"
ssh -o ConnectTimeout=8 -o BatchMode=yes "$WORKER" "docker image inspect '$IMG'" >/dev/null 2>&1 && ok "image $IMG (worker)" || warn "image $IMG missing (worker) — build pending"

# --- Weights present (head) ---
WT="$HF_CACHE/hub/models--deepseek-ai--DeepSeek-V4-Flash-0731"
if [ -d "$WT" ]; then
  cnt=$(find "$WT/blobs" -type f ! -name '*.incomplete' 2>/dev/null | wc -l); inc=$(find "$WT/blobs" -name '*.incomplete' 2>/dev/null | wc -l)
  ok "weights dir exists (head): $cnt complete blobs, $inc incomplete"
  [ "$inc" -gt 0 ] && warn "$inc shards still downloading" || true
else warn "weights dir missing (head) — download not started"; fi

# --- Model repo env consistent (no old -DSpark repo leak) ---
if grep -q 'DSPARK_MODEL=deepseek-ai/DeepSeek-V4-Flash-0731' /home/sakkout/ds4-0731-recipe/.env.dspark 2>/dev/null; then
  ok ".env.dspark -> 0731 checkpoint"; else bad ".env.dspark NOT pointing at 0731 checkpoint"; fi

echo "== preflight summary: $PASS ok, $WARN warn, $FAIL fail =="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
