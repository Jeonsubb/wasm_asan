#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }
}
need_cmd wat2wasm
need_cmd wasm-interp

ensure_dir "$POC_DIR"

wat2wasm "$WAT_SRC_DIR/mini_asan_singlemem.wat" -o "$POC_DIR/mini_asan_singlemem.wasm"
wat2wasm --enable-multi-memory "$WAT_SRC_DIR/mini_asan_multimem.wat" -o "$POC_DIR/mini_asan_multimem.wasm"

single_raw=$(wasm-interp "$POC_DIR/mini_asan_singlemem.wasm" -r demo | awk -F'i32:' '{print $2}' | tr -d '[:space:]')
multi_raw=$(wasm-interp "$POC_DIR/mini_asan_multimem.wasm" --enable-multi-memory -r demo | awk -F'i32:' '{print $2}' | tr -d '[:space:]')

if [[ -z "$single_raw" || -z "$multi_raw" ]]; then
  echo "failed to parse demo() outputs" >&2
  exit 1
fi

single_before=$(( (single_raw >> 8) & 0xff ))
single_after=$(( single_raw & 0xff ))
multi_before=$(( (multi_raw >> 8) & 0xff ))
multi_after=$(( multi_raw & 0xff ))

echo "[single-mem] shadow before=$single_before after_attack=$single_after"
echo "[multi-mem ] shadow before=$multi_before after_attack=$multi_after"

if [[ "$single_after" != "$single_before" && "$multi_after" == "$multi_before" ]]; then
  echo "Observation: single-memory shadow can be corrupted by mem0 writes, multi-memory shadow is isolated."
fi
