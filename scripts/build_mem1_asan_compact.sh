#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

SRC=${1:-$SRC_DIR/asan_probe.cpp}
OUT_PREFIX=${2:-$GENERATED_DIR/asan_compact_mem1}

ensure_dir "$(dirname "$OUT_PREFIX")"

em++ "$SRC" -O0 -g -fsanitize=address -emit-llvm -c -o "${OUT_PREFIX}.bc"

"$PASS_DIR/build.sh" >/dev/null
opt-15 -load-pass-plugin "$PASS_DIR/libAsanShadowAbstraction.so" \
  -passes=asan-shadow-abstraction "${OUT_PREFIX}.bc" -o "${OUT_PREFIX}.abs.bc"

emcc "$SRC_DIR/asan_shadow_hooks.c" -O0 -emit-llvm -c -o "${OUT_PREFIX}.hooks.bc"
llvm-link-15 "${OUT_PREFIX}.abs.bc" "${OUT_PREFIX}.hooks.bc" -o "${OUT_PREFIX}.linked.bc"

em++ "${OUT_PREFIX}.linked.bc" -O0 -g -fsanitize=address \
  -sSTANDALONE_WASM=1 \
  -sALLOW_MEMORY_GROWTH=1 \
  -sINITIAL_MEMORY=64MB \
  -o "${OUT_PREFIX}.wasm"

wasm2wat "${OUT_PREFIX}.wasm" -o "${OUT_PREFIX}.wat"
"$SCRIPT_DIR/transform_asan_to_mem1.py" "${OUT_PREFIX}.wat" "${OUT_PREFIX}.mem1.wat" --compact-mem1
wat2wasm --enable-multi-memory "${OUT_PREFIX}.mem1.wat" -o "${OUT_PREFIX}.mem1.wasm"

echo "Built: ${OUT_PREFIX}.mem1.wasm"
