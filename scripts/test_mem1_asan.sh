#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

WASM=${1:-$GENERATED_DIR/asan_mem1_mem1.wasm}

if [[ ! -f "$WASM" ]]; then
  echo "missing $WASM. run scripts/build_mem1_asan.sh first" >&2
  exit 1
fi

raw=$(wasm-interp "$WASM" --enable-multi-memory --dummy-import-func -r mem1_selftest | awk -F'i32:' '{print $2}' | tr -d '[:space:]')
if [[ -z "$raw" ]]; then
  echo "failed to parse mem1_selftest output" >&2
  exit 1
fi

before=$(( (raw >> 16) & 0xff ))
after=$(( (raw >> 8) & 0xff ))
poisoned=$(( raw & 0xff ))

printf "mem1_selftest: before=0x%02x after_mem0_poke=0x%02x is_poisoned=%d\n" "$before" "$after" "$poisoned"

if wasm-objdump -x "$WASM" | rg -q "mem1_selftest_store4"; then
  store_out=$(wasm-interp "$WASM" --enable-multi-memory --dummy-import-func -r mem1_selftest_store4 2>&1 || true)
  if echo "$store_out" | rg -q "error: unreachable executed"; then
    echo "mem1_selftest_store4: expected trap observed"
  else
    echo "mem1_selftest_store4: unexpected success (expected ASan trap path)"
    echo "$store_out"
    exit 1
  fi
else
  echo "mem1_selftest_store4: skipped (export not present in this build)"
fi
