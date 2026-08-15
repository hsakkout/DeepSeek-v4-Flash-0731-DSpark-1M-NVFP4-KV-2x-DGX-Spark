# Speed update — 2026-07-16: 70 tok/s single-stream (beats documented 53-60)

Re-measured DS4-Flash on the 2× DGX Spark (GB10) pair using the on-node production image, and it lands **above** the previously documented 53-60 tok/s.

## Measured (single-stream, temperature 0, warm)

| Workload | tok/s |
|---|---|
| **Code** (BST implementation) | **70.3** (504 tok / 7.17 s) |
| **Math** (running prime sum) | **70.5** (687 tok / 9.75 s) |

**dspark acceptance: 82%**, mean accept length **5.1 / 5** — the matched native drafter accepts nearly every speculative token (per-position: 0.985 / 0.910 / 0.866 / 0.776 / 0.575).

This **meets the 66-70 tok/s target** and beats the repo's documented 53-60 — the `mia-raf-...concurrency-p2b` production image + dspark k=5 is faster than the earlier documented config.

## Config that produced it

- **Image:** `vllm-dspark-runtime:mia-raf-pr1-nvfp4-probe-c-keys-concurrency-p2b`
  ⚠️ **This is a LOCAL-ONLY tag. It is not published to any registry and you cannot pull it.**
  It should not have appeared in a public doc unmarked (see [#12](../../issues/12)).
  To reproduce this runtime without building it yourself, use the
  [`sparkrun/`](sparkrun/) recipe, which pins a public base image by digest and rebuilds the
  stage-c overlay in-container. For a one-pull prebuilt alternative see
  [`RUNTIME-BAKEOFF-2026-07-29.md`](RUNTIME-BAKEOFF-2026-07-29.md).
- **Model:** `fraserprice/DeepSeek-V4-Flash-DSpark` (local, `/cache/huggingface/fraserprice/DeepSeek-V4-Flash-DSpark`)
- **TP2** across Bluey (192.168.192.1) + Reddie (192.168.192.2), `--distributed-executor-backend mp`
- **KV:** `nvfp4_ds_mla`, `--block-size 256`, `--max-model-len 1048576` → **1,243,449-token** KV pool
- **`--gpu-memory-utilization 0.78`, `--max-num-seqs 6`, `--max-num-batched-tokens 8192`**
- **Spec:** `{"method":"dspark","num_speculative_tokens":5}`
- Parsers: `deepseek_v4` (tokenizer / tool / reasoning), thinking disabled

## Launcher — `scripts/ds4run.sh`

This image ships with the **full head command baked into `CMD`** (ENTRYPOINT=`bash`), so a docker-run launcher that reuses the baked command and only flips node-rank for the worker is the cleanest way to bring it up on this cluster. `scripts/ds4run.sh <0|1>` does exactly that, with the proven RoCE settings (`rocep1s0f0` / GID 3 / `enp1s0f0np0`). Worker-first:

```bash
# on Reddie (rank 1):
bash ds4run.sh 1
# then on Bluey (rank 0):
bash ds4run.sh 0
# serves :8888 (model id deepseek-v4-flash-dspark), ~10-12 min boot
```

## Gotchas hit during bring-up (churned fleet)

1. **Model was on only one node.** `fraserprice/DeepSeek-V4-Flash-DSpark` (159 G) was on Bluey but not Reddie — rsync it over the fabric first (both nodes need it for TP2).
2. **compose `command:` collides with the baked ENTRYPOINT.** `docker-compose.dspark.yml` overrides `command:` with `bash -lc ...`, but the on-node image already has ENTRYPOINT=`bash` + the command in `CMD` → `bash bash -lc …` → exit 126 "cannot execute binary file". Use the docker-run launcher above (or an image whose entrypoint the compose expects).
3. **Node-path assumption.** `start-deepseek-v4-flash-dspark.sh` scps to the *head's* home path on the worker; if the worker user differs (`tonyspark1` vs `tonyspark2`), that fails. The docker-run launcher sidesteps it.

## Untested further levers (for next pass)

- `VLLM_USE_B12X_WO_PROJECTION=1` (README lists it as a verified speed env; the current run left it at default 0 and still hit 70).
- dspark k sweep (5 → 6/8) — note position-5 acceptance is already ~0.58, so higher k has diminishing returns.
- gmu 0.78 → 0.90 (KV headroom; single-stream decode isn't KV-bound so likely marginal).
