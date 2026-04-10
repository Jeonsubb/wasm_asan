#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

OUT_MD=${1:-$DOCS_DIR/asan_optional_features.md}
ensure_dir "$(dirname "$OUT_MD")"

if [[ ! -f "$GENERATED_DIR/env_stub_asan.wasm" ]]; then
  build_env_stub "$GENERATED_DIR/env_stub_asan.wasm" >/dev/null
fi

tmpdir=$(mktemp -d /tmp/asan-optional.XXXXXX)
trap 'rm -rf "$tmpdir"' EXIT

run_capture() {
  local out=$1
  shift
  "$@" >"$out" 2>&1 || true
}

status_of() {
  local file=$1
  if rg -q "AddressSanitizer: stack-use-after-return" "$file"; then
    echo "stack-use-after-return"
  elif rg -q "AddressSanitizer:" "$file"; then
    echo "asan-other"
  elif rg -q "init_order a=0" "$file"; then
    echo "passthrough"
  elif rg -q "done mode=use_after_return" "$file"; then
    echo "passthrough"
  else
    echo "unknown"
  fi
}

# use-after-return enabled
run_capture "$tmpdir/uar_base.txt" /bin/bash -lc \
  "em++ '$SRC_DIR/asan_probe.cpp' -O0 -g -fsanitize=address -fsanitize-address-use-after-return=always -sSTANDALONE_WASM=1 -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=64MB -o $tmpdir/uar_base.wasm && '$SCRIPT_DIR/run_with_wasmtime.sh' $tmpdir/uar_base.wasm use_after_return"

run_capture "$tmpdir/uar_mem1.txt" /bin/bash -lc \
  "em++ '$SRC_DIR/asan_probe.cpp' -O0 -g -fsanitize=address -fsanitize-address-use-after-return=always -emit-llvm -c -o $tmpdir/uar_mem1.bc && '$PASS_DIR/build.sh' >/dev/null && opt-15 -load-pass-plugin '$PASS_DIR/libAsanShadowAbstraction.so' -passes=asan-shadow-abstraction $tmpdir/uar_mem1.bc -o $tmpdir/uar_mem1.abs.bc && emcc '$SRC_DIR/asan_shadow_hooks.c' -O0 -emit-llvm -c -o $tmpdir/uar_mem1.hooks.bc && llvm-link-15 $tmpdir/uar_mem1.abs.bc $tmpdir/uar_mem1.hooks.bc -o $tmpdir/uar_mem1.linked.bc && em++ $tmpdir/uar_mem1.linked.bc -O0 -g -fsanitize=address -fsanitize-address-use-after-return=always -sSTANDALONE_WASM=1 -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=64MB -o $tmpdir/uar_mem1.wasm && wasm2wat $tmpdir/uar_mem1.wasm -o $tmpdir/uar_mem1.wat && '$SCRIPT_DIR/transform_asan_to_mem1.py' $tmpdir/uar_mem1.wat $tmpdir/uar_mem1.mem1.wat && wat2wasm --enable-multi-memory $tmpdir/uar_mem1.mem1.wat -o $tmpdir/uar_mem1.mem1.wasm && '$SCRIPT_DIR/run_with_wasmtime.sh' $tmpdir/uar_mem1.mem1.wasm use_after_return"

# initialization order runtime option
run_capture "$tmpdir/init_base.txt" /bin/bash -lc \
  "em++ '$SRC_DIR/init_order_a.cpp' '$SRC_DIR/init_order_b.cpp' -O0 -g -fsanitize=address -sSTANDALONE_WASM=1 -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=64MB -o $tmpdir/init_base.wasm && XDG_CACHE_HOME=/tmp ASAN_OPTIONS=check_initialization_order=1 ~/.wasmtime/bin/wasmtime run --preload env='$GENERATED_DIR/env_stub_asan.wasm' --env ASAN_OPTIONS=check_initialization_order=1 $tmpdir/init_base.wasm"

run_capture "$tmpdir/init_mem1.txt" /bin/bash -lc \
  "em++ '$SRC_DIR/init_order_a.cpp' -O0 -g -fsanitize=address -emit-llvm -c -o $tmpdir/init_a.bc && em++ '$SRC_DIR/init_order_b.cpp' -O0 -g -fsanitize=address -emit-llvm -c -o $tmpdir/init_b.bc && '$PASS_DIR/build.sh' >/dev/null && opt-15 -load-pass-plugin '$PASS_DIR/libAsanShadowAbstraction.so' -passes=asan-shadow-abstraction $tmpdir/init_a.bc -o $tmpdir/init_a.abs.bc && opt-15 -load-pass-plugin '$PASS_DIR/libAsanShadowAbstraction.so' -passes=asan-shadow-abstraction $tmpdir/init_b.bc -o $tmpdir/init_b.abs.bc && emcc '$SRC_DIR/asan_shadow_hooks.c' -O0 -emit-llvm -c -o $tmpdir/init_hooks.bc && llvm-link-15 $tmpdir/init_a.abs.bc $tmpdir/init_b.abs.bc $tmpdir/init_hooks.bc -o $tmpdir/init.linked.bc && em++ $tmpdir/init.linked.bc -O0 -g -fsanitize=address -sSTANDALONE_WASM=1 -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=64MB -o $tmpdir/init_mem1.wasm && wasm2wat $tmpdir/init_mem1.wasm -o $tmpdir/init_mem1.wat && '$SCRIPT_DIR/transform_asan_to_mem1.py' $tmpdir/init_mem1.wat $tmpdir/init_mem1.mem1.wat && wat2wasm --enable-multi-memory $tmpdir/init_mem1.mem1.wat -o $tmpdir/init_mem1.mem1.wasm && XDG_CACHE_HOME=/tmp ASAN_OPTIONS=check_initialization_order=1 ~/.wasmtime/bin/wasmtime run --preload env='$GENERATED_DIR/env_stub_asan.wasm' --env ASAN_OPTIONS=check_initialization_order=1 $tmpdir/init_mem1.mem1.wasm"

{
  echo "| Feature | Baseline | mem1 | Match |"
  echo "| --- | --- | --- | --- |"
  b=$(status_of "$tmpdir/uar_base.txt")
  m=$(status_of "$tmpdir/uar_mem1.txt")
  printf '| use-after-return (`-fsanitize-address-use-after-return=always`) | %s | %s | %s |\n' "$b" "$m" "$([[ "$b" == "$m" ]] && echo YES || echo NO)"
  b=$(status_of "$tmpdir/init_base.txt")
  m=$(status_of "$tmpdir/init_mem1.txt")
  printf '| initialization-order (`ASAN_OPTIONS=check_initialization_order=1`) | %s | %s | %s |\n' "$b" "$m" "$([[ "$b" == "$m" ]] && echo YES || echo NO)"
} >"$OUT_MD"

cat "$OUT_MD"
