#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

ROOT=${1:-$POLYBENCH_ROOT}
BENCH_REL=${2:-linear-algebra/blas/gemm/gemm}
DATASET=${3:-MEDIUM_DATASET}
OUT_PREFIX=${4:-$GENERATED_DIR/polybench_build}

ensure_dir "$(dirname "$OUT_PREFIX")"

BENCH_C="$ROOT/${BENCH_REL}.c"
BENCH_DIR=$(dirname "$BENCH_C")
BENCH_BASE=$(basename "$BENCH_REL")
UTIL_C="$ROOT/utilities/polybench.c"

if [[ ! -f "$BENCH_C" ]]; then
  echo "missing benchmark source: $BENCH_C" >&2
  exit 1
fi

COMMON_FLAGS=(
  -O3
  -I "$ROOT/utilities"
  -I "$BENCH_DIR"
  -D"$DATASET"
  -DPOLYBENCH_TIME
  -sSTANDALONE_WASM=1
  -sALLOW_MEMORY_GROWTH=1
  -sINITIAL_MEMORY=64MB
)

# OFF
emcc "$UTIL_C" "$BENCH_C" "${COMMON_FLAGS[@]}" -o "${OUT_PREFIX}.off.wasm"

# ON single-memory
emcc "$UTIL_C" "$BENCH_C" "${COMMON_FLAGS[@]}" -fsanitize=address -o "${OUT_PREFIX}.on.wasm"

# ON mem1
emcc "$UTIL_C" -O3 -I "$ROOT/utilities" -D"$DATASET" -DPOLYBENCH_TIME -fsanitize=address -emit-llvm -c -o "${OUT_PREFIX}.polybench.bc"
emcc "$BENCH_C" -O3 -I "$ROOT/utilities" -I "$BENCH_DIR" -D"$DATASET" -DPOLYBENCH_TIME -fsanitize=address -emit-llvm -c -o "${OUT_PREFIX}.${BENCH_BASE}.bc"
"$PASS_DIR/build.sh" >/dev/null
opt-15 -load-pass-plugin "$PASS_DIR/libAsanShadowAbstraction.so" -passes=asan-shadow-abstraction "${OUT_PREFIX}.polybench.bc" -o "${OUT_PREFIX}.polybench.abs.bc"
opt-15 -load-pass-plugin "$PASS_DIR/libAsanShadowAbstraction.so" -passes=asan-shadow-abstraction "${OUT_PREFIX}.${BENCH_BASE}.bc" -o "${OUT_PREFIX}.${BENCH_BASE}.abs.bc"
emcc "$SRC_DIR/asan_shadow_hooks.c" -O0 -emit-llvm -c -o "${OUT_PREFIX}.hooks.bc"
llvm-link-15 "${OUT_PREFIX}.polybench.abs.bc" "${OUT_PREFIX}.${BENCH_BASE}.abs.bc" "${OUT_PREFIX}.hooks.bc" -o "${OUT_PREFIX}.linked.bc"
em++ "${OUT_PREFIX}.linked.bc" -O3 -fsanitize=address \
  -sSTANDALONE_WASM=1 \
  -sALLOW_MEMORY_GROWTH=1 \
  -sINITIAL_MEMORY=64MB \
  -o "${OUT_PREFIX}.mem1.tmp.wasm"
wasm2wat "${OUT_PREFIX}.mem1.tmp.wasm" -o "${OUT_PREFIX}.mem1.tmp.wat"
"$SCRIPT_DIR/transform_asan_to_mem1.py" "${OUT_PREFIX}.mem1.tmp.wat" "${OUT_PREFIX}.mem1.wat" --no-selftest
wat2wasm --enable-multi-memory "${OUT_PREFIX}.mem1.wat" -o "${OUT_PREFIX}.mem1.wasm"

echo "Built:"
echo "  ${OUT_PREFIX}.off.wasm"
echo "  ${OUT_PREFIX}.on.wasm"
echo "  ${OUT_PREFIX}.mem1.wasm"
