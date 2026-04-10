#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

SRC=${1:-$SRC_DIR/asan_probe.cpp}
IN_BC=${2:-$GENERATED_DIR/asan_inline.bc}
OUT_LL=${3:-$GENERATED_DIR/asan_inline.abs.ll}

ensure_dir "$(dirname "$IN_BC")"
ensure_dir "$(dirname "$OUT_LL")"

if [[ ! -f "$IN_BC" ]]; then
  em++ "$SRC" -O0 -g -fsanitize=address -emit-llvm -c -o "$IN_BC"
fi

"$PASS_DIR/build.sh" >/dev/null

opt-15 -load-pass-plugin "$PASS_DIR/libAsanShadowAbstraction.so" \
  -passes=asan-shadow-abstraction "$IN_BC" -S -o "$OUT_LL"

echo "written: $OUT_LL"
echo "helper calls inserted:"
rg -n "__asan_shadow_load8|__asan_shadow_store8" "$OUT_LL" | wc -l | awk '{print $1}'
