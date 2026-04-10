#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

SRC=${1:-$SRC_DIR/asan_probe.cpp}
OUT_PREFIX=${2:-$GENERATED_DIR/asan_mem1}

ensure_dir "$(dirname "$OUT_PREFIX")"

# 1) Build call-based ASan wasm to keep checks centralized in __asan_load/store* helpers
em++ "$SRC" -O0 -g -fsanitize=address \
  -mllvm -asan-instrumentation-with-call-threshold=0 \
  -sSTANDALONE_WASM=1 \
  -sALLOW_MEMORY_GROWTH=1 \
  -sINITIAL_MEMORY=64MB \
  -o "${OUT_PREFIX}_calls.wasm"

# 2) Convert to WAT, patch target ASan shadow ops to memory 1, and rebuild
wasm2wat "${OUT_PREFIX}_calls.wasm" -o "${OUT_PREFIX}_calls.wat"
"$SCRIPT_DIR/transform_asan_to_mem1.py" "${OUT_PREFIX}_calls.wat" "${OUT_PREFIX}_mem1.wat"
wat2wasm --enable-multi-memory "${OUT_PREFIX}_mem1.wat" -o "${OUT_PREFIX}_mem1.wasm"

echo "Built: ${OUT_PREFIX}_mem1.wasm"
