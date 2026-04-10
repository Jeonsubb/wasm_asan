#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

WASMTIME_BIN=${WASMTIME_BIN:-$HOME/.wasmtime/bin/wasmtime}
ENV_STUB=${ENV_STUB:-$GENERATED_DIR/env_stub_asan.wasm}
WASM=${1:-$GENERATED_DIR/asan_on.wasm}
MODE=${2:-heap_oob}
shift 2 || true

if [[ ! -x "$WASMTIME_BIN" ]]; then
  echo "wasmtime not found at $WASMTIME_BIN" >&2
  exit 1
fi
if [[ ! -f "$ENV_STUB" ]]; then
  build_env_stub "$ENV_STUB" >/dev/null
fi

extra_args=()
if [[ -n "${ASAN_OPTIONS:-}" ]]; then
  extra_args+=(--env "ASAN_OPTIONS=${ASAN_OPTIONS}")
fi
if [[ -n "${LSAN_OPTIONS:-}" ]]; then
  extra_args+=(--env "LSAN_OPTIONS=${LSAN_OPTIONS}")
fi

XDG_CACHE_HOME=/tmp "$WASMTIME_BIN" run --preload env="$ENV_STUB" "${extra_args[@]}" "$WASM" "$MODE" "$@"
