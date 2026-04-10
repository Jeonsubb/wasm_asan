#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

if [[ $# -lt 4 ]]; then
  echo "Usage: $0 <bench_name> <off.wasm> <on.wasm> <mem1.wasm> [runs=3]" >&2
  exit 2
fi

BENCH=$1
OFF=$2
ON=$3
MEM1=$4
RUNS=${5:-3}
WASMTIME_BIN=${WASMTIME_BIN:-$HOME/.wasmtime/bin/wasmtime}
ENV_STUB=${ENV_STUB:-$GENERATED_DIR/env_stub_asan.wasm}

if [[ ! -f "$ENV_STUB" ]]; then
  build_env_stub "$ENV_STUB" >/dev/null
fi

measure_one() {
  local variant=$1
  local wasm=$2
  local idx=$3
  local out
  out=$(/usr/bin/time -f '%e\t%M' env XDG_CACHE_HOME=/tmp "$WASMTIME_BIN" run --preload env="$ENV_STUB" "$wasm" 2>&1 >/tmp/polybench-run.$$)
  local sec rss
  sec=$(echo "$out" | tail -n1 | cut -f1)
  rss=$(echo "$out" | tail -n1 | cut -f2)
  printf "%s\t%s\t%d\t%s\t%s\n" "$BENCH" "$variant" "$idx" "$sec" "$rss"
}

printf "bench\tvariant\trun\tseconds\tmax_rss_kb\n"
for i in $(seq 1 "$RUNS"); do
  measure_one off "$OFF" "$i"
  measure_one on "$ON" "$i"
  measure_one mem1 "$MEM1" "$i"
done
