#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

SRC=${1:-$SRC_DIR/asan_probe.cpp}
BASE=${2:-$GENERATED_DIR/asan_on_verify}
MEM1=${3:-$GENERATED_DIR/asan_mem1_verify}

ensure_dir "$(dirname "$BASE")"
ensure_dir "$(dirname "$MEM1")"

"$SCRIPT_DIR/build_mem1_asan_inline.sh" "$SRC" "$MEM1" >/dev/null
em++ "$SRC" -O0 -g -fsanitize=address \
  -sSTANDALONE_WASM=1 \
  -sALLOW_MEMORY_GROWTH=1 \
  -sINITIAL_MEMORY=64MB \
  -o "${BASE}.wasm"

tmpdir=$(mktemp -d /tmp/asan-mem1-verify.XXXXXX)
trap 'rm -rf "$tmpdir"' EXIT

check_mode() {
  local mode=$1
  local expect=$2
  local base_out="$tmpdir/${mode}.base.txt"
  local mem1_out="$tmpdir/${mode}.mem1.txt"

  "$SCRIPT_DIR/run_with_wasmtime.sh" "${BASE}.wasm" "$mode" >"$base_out" 2>&1 || true
  "$SCRIPT_DIR/run_with_wasmtime.sh" "${MEM1}.mem1.wasm" "$mode" >"$mem1_out" 2>&1 || true

  printf '=== %s ===\n' "$mode"

  if ! rg -q "$expect" "$base_out"; then
    echo "baseline missing expected pattern: $expect"
    sed -n '1,40p' "$base_out"
    return 1
  fi
  if ! rg -q "$expect" "$mem1_out"; then
    echo "mem1 missing expected pattern: $expect"
    sed -n '1,40p' "$mem1_out"
    return 1
  fi

  case "$mode" in
    global_oob)
      rg -q "Global redzone: +f9" "$mem1_out"
      ;;
    stack_oob)
      rg -q "Stack left redzone: +f1" "$mem1_out"
      rg -q "Stack right redzone: +f3" "$mem1_out"
      ;;
    heap_oob)
      rg -q "Heap left redzone: +fa" "$mem1_out"
      ;;
    use_after_free)
      rg -q "Freed heap region: +fd" "$mem1_out"
      ;;
    use_after_scope)
      rg -q "Stack use after scope: +f8" "$mem1_out"
      ;;
  esac

  echo "baseline: $(rg -o 'AddressSanitizer: [^ ]+' -m1 "$base_out")"
  echo "mem1    : $(rg -o 'AddressSanitizer: [^ ]+' -m1 "$mem1_out")"
  echo "status  : OK"
  echo
}

check_passthrough_mode() {
  local mode=$1
  local success_pat=$2
  local base_out="$tmpdir/${mode}.base.txt"
  local mem1_out="$tmpdir/${mode}.mem1.txt"

  "$SCRIPT_DIR/run_with_wasmtime.sh" "${BASE}.wasm" "$mode" >"$base_out" 2>&1 || true
  "$SCRIPT_DIR/run_with_wasmtime.sh" "${MEM1}.mem1.wasm" "$mode" >"$mem1_out" 2>&1 || true

  printf '=== %s ===\n' "$mode"

  if rg -q "AddressSanitizer:" "$base_out"; then
    echo "baseline unexpectedly reported ASan error"
    sed -n '1,40p' "$base_out"
    return 1
  fi
  if rg -q "AddressSanitizer:" "$mem1_out"; then
    echo "mem1 unexpectedly reported ASan error"
    sed -n '1,40p' "$mem1_out"
    return 1
  fi
  rg -q "$success_pat" "$base_out"
  rg -q "$success_pat" "$mem1_out"

  echo "baseline: passthrough"
  echo "mem1    : passthrough"
  echo "status  : OK"
  echo
}

check_mode heap_oob "AddressSanitizer: heap-buffer-overflow"
check_mode stack_oob "AddressSanitizer: stack-buffer-overflow"
check_mode global_oob "AddressSanitizer: global-buffer-overflow"
check_mode use_after_free "AddressSanitizer: heap-use-after-free"
check_mode double_free "AddressSanitizer: attempting double-free"
check_mode invalid_free "AddressSanitizer: attempting free on address which was not malloc\\(\\)-ed"
check_mode use_after_scope "AddressSanitizer: stack-use-after-scope"
check_passthrough_mode alloc_dealloc_mismatch "done mode=alloc_dealloc_mismatch"
check_passthrough_mode use_after_return "done mode=use_after_return"

echo "mem1 equivalence check passed for current baseline-supported and baseline-unsupported ASan behaviors."
