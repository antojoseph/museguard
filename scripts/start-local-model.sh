#!/usr/bin/env bash
set -euo pipefail
MUSE_MODEL_HOME="${MUSE_MODEL_HOME:-$HOME/Library/Application Support/MuseGuard/LocalModel}"
exec "$MUSE_MODEL_HOME/runtime/llama-server" \
  -m "$MUSE_MODEL_HOME/weights/Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf" \
  --mmproj "$MUSE_MODEL_HOME/weights/mmproj-Muse-Glimmer-30B-Q4_K_M.gguf" \
  --alias muse-glimmer --host 127.0.0.1 --port 8787 \
  --api-key-file "$MUSE_MODEL_HOME/api-key" \
  -ngl 99 -c 16384 -np 1 --jinja --no-webui \
  --chat-template-kwargs '{"reasoning_strength":"low"}' --reasoning-budget 256
