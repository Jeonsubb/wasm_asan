#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

SRC=${1:-$SRC_DIR/asan_probe.cpp}
OUT_PREFIX=${2:-$GENERATED_DIR/asan_inline_mem1}

ensure_dir "$(dirname "$OUT_PREFIX")"

# 1) Compile ASan with default instrumentation (inline path included)
em++ "$SRC" -O0 -g -fsanitize=address -emit-llvm -c -o "${OUT_PREFIX}.bc"

# 2) Rewrite inline ASan shadow load/store i8 to abstraction helper calls
"$PASS_DIR/build.sh" >/dev/null
opt-15 -load-pass-plugin "$PASS_DIR/libAsanShadowAbstraction.so" \
  -passes=asan-shadow-abstraction "${OUT_PREFIX}.bc" -o "${OUT_PREFIX}.abs.bc"

# 3) Link helper implementations
emcc "$SRC_DIR/asan_shadow_hooks.c" -O0 -emit-llvm -c -o "${OUT_PREFIX}.hooks.bc"
llvm-link-15 "${OUT_PREFIX}.abs.bc" "${OUT_PREFIX}.hooks.bc" -o "${OUT_PREFIX}.linked.bc"

# 4) Link to wasm (single memory ASan baseline artifact)
em++ "${OUT_PREFIX}.linked.bc" -O0 -g -fsanitize=address \
  -sSTANDALONE_WASM=1 \
  -sALLOW_MEMORY_GROWTH=1 \
  -sINITIAL_MEMORY=64MB \
  -o "${OUT_PREFIX}.wasm"

# 5) Apply existing mem1 WAT rewrite pipeline
wasm2wat "${OUT_PREFIX}.wasm" -o "${OUT_PREFIX}.wat"
"$SCRIPT_DIR/transform_asan_to_mem1.py" "${OUT_PREFIX}.wat" "${OUT_PREFIX}.mem1.wat"
wat2wasm --enable-multi-memory "${OUT_PREFIX}.mem1.wat" -o "${OUT_PREFIX}.mem1.wasm"

echo "Built: ${OUT_PREFIX}.mem1.wasm"
