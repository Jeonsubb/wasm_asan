#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

SRC=${1:-$SRC_DIR/asan_probe.cpp}
BASE=${2:-$GENERATED_DIR/asan_metrics_base}
COMPACT=${3:-$GENERATED_DIR/asan_metrics_compact}
OUT=${4:-$REPORTS_DIR/compact_metrics.tsv}
REPEAT=${REPEAT:-3}

ensure_dir "$(dirname "$BASE")"
ensure_dir "$(dirname "$COMPACT")"
ensure_dir "$(dirname "$OUT")"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }
}

need_cmd /usr/bin/time
need_cmd wasm2wat
need_cmd rg
need_cmd awk

"$SCRIPT_DIR/build_mem1_asan_compact.sh" "$SRC" "$COMPACT" >/dev/null
em++ "$SRC" -O0 -g -fsanitize=address \
  -sSTANDALONE_WASM=1 \
  -sALLOW_MEMORY_GROWTH=1 \
  -sINITIAL_MEMORY=64MB \
  -o "${BASE}.wasm"

extract_mem_decl() {
  local wat=$1
  local memidx=$2
  rg "^\s*\(memory \(;${memidx};\)" "$wat" | head -n1 | sed -E 's/.*\(;[0-9]+;\)\s+([0-9]+)\s+([0-9]+)\).*/\1\t\2/'
}

extract_first_data() {
  local wat=$1
  rg -o "\(data .*i32.const [0-9]+" "$wat" | head -n1 | rg -o "[0-9]+$"
}

run_one() {
  local label=$1
  local wasm=$2
  local mode=$3
  local arg1=$4
  local arg2=$5
  local tmpf
  tmpf=$(mktemp)
  /usr/bin/time -f '%e\t%M' "$SCRIPT_DIR/run_with_wasmtime.sh" "$wasm" "$mode" "$arg1" "$arg2" >/dev/null 2>"$tmpf" || true
  local wall rss
  wall=$(awk -F'\t' 'NF==2{print $1}' "$tmpf" | tail -n1)
  rss=$(awk -F'\t' 'NF==2{print $2}' "$tmpf" | tail -n1)
  rm -f "$tmpf"
  printf "%s\t%s\t%s\t%s\n" "$label" "$mode" "$wall" "$rss"
}

echo -e "section\tvariant\tfield\tvalue" > "$OUT"

for item in "${BASE}.wasm:${BASE}.wat:base" "${COMPACT}.mem1.wasm:${COMPACT}.mem1.wat:compact_mem1"; do
  IFS=: read -r wasm wat label <<< "$item"
  if [[ "$label" == "compact_mem1" ]]; then
    wasm2wat --enable-multi-memory "$wasm" -o "$wat"
  else
    wasm2wat "$wasm" -o "$wat"
  fi
  read -r mem0_init mem0_max < <(extract_mem_decl "$wat" 0)
  printf "layout\t%s\tmem0_init_pages\t%s\n" "$label" "$mem0_init" >> "$OUT"
  printf "layout\t%s\tmem0_max_pages\t%s\n" "$label" "$mem0_max" >> "$OUT"
  if [[ "$label" != "base" ]]; then
    read -r mem1_init mem1_max < <(extract_mem_decl "$wat" 1)
    printf "layout\t%s\tmem1_init_pages\t%s\n" "$label" "$mem1_init" >> "$OUT"
    printf "layout\t%s\tmem1_max_pages\t%s\n" "$label" "$mem1_max" >> "$OUT"
  fi
  printf "layout\t%s\tfirst_data_offset\t%s\n" "$label" "$(extract_first_data "$wat")" >> "$OUT"
done

tmpbench=$(mktemp)
echo -e "variant\tmode\twall\tmax_rss_kb" > "$tmpbench"
for _ in $(seq 1 "$REPEAT"); do
  run_one base "${BASE}.wasm" bench1 20 64 >> "$tmpbench"
  run_one compact_mem1 "${COMPACT}.mem1.wasm" bench1 20 64 >> "$tmpbench"
  run_one base "${BASE}.wasm" bench2 50000 4096 >> "$tmpbench"
  run_one compact_mem1 "${COMPACT}.mem1.wasm" bench2 50000 4096 >> "$tmpbench"
done

awk -F'\t' '
NR==1 {next}
{
  key=$1 "|" $2
  sec=$3+0
  rss=$4+0
  c[key]++
  st[key]+=sec
  st2[key]+=sec*sec
  sr[key]+=rss
  sr2[key]+=rss*rss
}
END {
  for (k in c) {
    n=c[k]
    mt=st[k]/n
    mr=sr[k]/n
    vt=(st2[k]/n)-(mt*mt); if (vt < 0) vt=0
    vr=(sr2[k]/n)-(mr*mr); if (vr < 0) vr=0
    split(k,p,"|")
    printf "bench\t%s\t%s_mean_time_s\t%.6f\n", p[1], p[2], mt
    printf "bench\t%s\t%s_std_time_s\t%.6f\n", p[1], p[2], sqrt(vt)
    printf "bench\t%s\t%s_mean_rss_kb\t%.1f\n", p[1], p[2], mr
    printf "bench\t%s\t%s_std_rss_kb\t%.1f\n", p[1], p[2], sqrt(vr)
  }
}' "$tmpbench" >> "$OUT"

rm -f "$tmpbench"
echo "Wrote $OUT"
column -t -s $'\t' "$OUT"
