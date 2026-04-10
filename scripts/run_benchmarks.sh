#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

OFF_WASM=${1:-$GENERATED_DIR/asan_off.wasm}
ON_WASM=${2:-$GENERATED_DIR/asan_on.wasm}
REPEAT=${REPEAT:-5}
OUT=${OUT:-$REPORTS_DIR/bench_results.tsv}

ensure_dir "$(dirname "$OUT")"

if [[ ! -f "$OFF_WASM" || ! -f "$ON_WASM" ]]; then
  echo "Usage: $0 [asan_off.wasm] [asan_on.wasm]" >&2
  echo "Requires scripts/run_wasi.js in this repository." >&2
  exit 1
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }
}
need_cmd node
need_cmd /usr/bin/time
need_cmd awk

run_one() {
  local label=$1
  local wasm=$2
  local mode=$3
  local arg1=$4
  local arg2=$5

  local tmpf
  tmpf=$(mktemp)
  /usr/bin/time -v node "$SCRIPT_DIR/run_wasi.js" "$wasm" "$mode" "$arg1" "$arg2" >/dev/null 2>"$tmpf" || true

  local wall rss
  wall=$(awk -F': ' '/Elapsed \(wall clock\) time/{print $2}' "$tmpf" | tail -n1)
  rss=$(awk -F': ' '/Maximum resident set size/{print $2}' "$tmpf" | tail -n1)
  rm -f "$tmpf"

  printf "%s\t%s\t%s\t%s\n" "$label" "$mode" "$wall" "$rss"
}

to_sec() {
  awk -v t="$1" 'BEGIN{
    n=split(t,a,":");
    if(n==3){print a[1]*3600+a[2]*60+a[3];}
    else if(n==2){print a[1]*60+a[2];}
    else {print t+0;}
  }'
}

collect_mode() {
  local mode=$1
  local arg1=$2
  local arg2=$3
  for i in $(seq 1 "$REPEAT"); do
    run_one OFF "$OFF_WASM" "$mode" "$arg1" "$arg2"
    run_one ON "$ON_WASM" "$mode" "$arg1" "$arg2"
  done
}

echo -e "variant\tmode\twall\tmax_rss_kb" > "$OUT"
collect_mode bench1 20 64 >> "$OUT"
collect_mode bench2 50000 4096 >> "$OUT"
collect_mode bench3 512 32 >> "$OUT"

echo "Raw results: $OUT"

echo
echo "Summary (mean/stddev of wall seconds and RSS KB):"
awk -F'\t' '
NR==1 {next}
{
  key=$1"|"$2
  sec=0
  n=split($3,a,":")
  if(n==3){sec=a[1]*3600+a[2]*60+a[3]}
  else if(n==2){sec=a[1]*60+a[2]}
  else {sec=$3+0}
  rss=$4+0
  c[key]++
  s_t[key]+=sec
  s2_t[key]+=sec*sec
  s_r[key]+=rss
  s2_r[key]+=rss*rss
}
END {
  printf "%-12s %-8s %12s %12s %12s %12s\n", "variant", "mode", "mean_t(s)", "std_t", "mean_rss", "std_rss"
  for (k in c) {
    n=c[k]
    mt=s_t[k]/n
    mr=s_r[k]/n
    vt=(s2_t[k]/n)-(mt*mt); if (vt<0) vt=0
    vr=(s2_r[k]/n)-(mr*mr); if (vr<0) vr=0
    st=sqrt(vt)
    sr=sqrt(vr)
    split(k,p,"|")
    printf "%-12s %-8s %12.4f %12.4f %12.1f %12.1f\n", p[1], p[2], mt, st, mr, sr
  }
}' "$OUT"
