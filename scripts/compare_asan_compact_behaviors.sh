#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

SRC=${1:-$SRC_DIR/asan_probe.cpp}
BASE=${2:-$GENERATED_DIR/asan_compact_compare_base}
COMPACT=${3:-$GENERATED_DIR/asan_compact_compare}
OUT_TSV=${4:-$REPORTS_DIR/asan_compact_behavior_matrix.tsv}
OUT_MD=${5:-$DOCS_DIR/asan_compact_behavior_matrix.md}

ensure_dir "$(dirname "$BASE")"
ensure_dir "$(dirname "$COMPACT")"
ensure_dir "$(dirname "$OUT_TSV")"
ensure_dir "$(dirname "$OUT_MD")"

modes=(
  heap_oob
  stack_oob
  global_oob
  use_after_free
  double_free
  invalid_free
  use_after_scope
  leak
  container_overflow
  alloc_dealloc_mismatch
  use_after_return
  exploit_global_shadow_unpoison
)

"$SCRIPT_DIR/build_mem1_asan_compact.sh" "$SRC" "$COMPACT" >/dev/null
em++ "$SRC" -O0 -g -fsanitize=address \
  -sSTANDALONE_WASM=1 \
  -sALLOW_MEMORY_GROWTH=1 \
  -sINITIAL_MEMORY=64MB \
  -o "${BASE}.wasm"

tmpdir=$(mktemp -d /tmp/asan-compact-compare.XXXXXX)
trap 'rm -rf "$tmpdir"' EXIT

extract_status() {
  local file=$1
  if rg -q "AddressSanitizer:" "$file"; then
    if rg -q "AddressSanitizer: heap-buffer-overflow" "$file"; then echo "heap-buffer-overflow"; return; fi
    if rg -q "AddressSanitizer: stack-buffer-overflow" "$file"; then echo "stack-buffer-overflow"; return; fi
    if rg -q "AddressSanitizer: global-buffer-overflow" "$file"; then echo "global-buffer-overflow"; return; fi
    if rg -q "AddressSanitizer: heap-use-after-free" "$file"; then echo "heap-use-after-free"; return; fi
    if rg -q "AddressSanitizer: stack-use-after-scope" "$file"; then echo "stack-use-after-scope"; return; fi
    if rg -q "AddressSanitizer: container-overflow" "$file"; then echo "container-overflow"; return; fi
    if rg -q "AddressSanitizer: attempting double-free" "$file"; then echo "double-free"; return; fi
    if rg -q "AddressSanitizer: attempting free on address which was not malloc\\(\\)-ed" "$file"; then echo "bad-free"; return; fi
    if rg -q "LeakSanitizer: detected memory leaks" "$file"; then echo "memory-leak"; return; fi
    echo "asan-other"
    return
  fi
  if rg -q "done mode=" "$file"; then
    echo "passthrough"
    return
  fi
  echo "unknown"
}

{
  printf "mode\tbaseline\tcompact_mem1\tmatch\n"
  for mode in "${modes[@]}"; do
    base_out="$tmpdir/${mode}.base.txt"
    compact_out="$tmpdir/${mode}.compact.txt"
    "$SCRIPT_DIR/run_with_wasmtime.sh" "${BASE}.wasm" "$mode" >"$base_out" 2>&1 || true
    "$SCRIPT_DIR/run_with_wasmtime.sh" "${COMPACT}.mem1.wasm" "$mode" >"$compact_out" 2>&1 || true

    base_status=$(extract_status "$base_out")
    compact_status=$(extract_status "$compact_out")
    match="NO"
    [[ "$base_status" == "$compact_status" ]] && match="YES"

    printf "%s\t%s\t%s\t%s\n" \
      "$mode" "$base_status" "$compact_status" "$match"
  done
} >"$OUT_TSV"

{
  echo "| Mode | Baseline | compact mem1 | Match |"
  echo "| --- | --- | --- | --- |"
  tail -n +2 "$OUT_TSV" | while IFS=$'\t' read -r mode baseline compact match; do
    printf "| %s | %s | %s | %s |\n" \
      "$mode" "$baseline" "$compact" "$match"
  done
} >"$OUT_MD"

echo "Wrote $OUT_TSV"
echo "Wrote $OUT_MD"
column -t -s $'\t' "$OUT_TSV"
