#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

ROOT=${1:-$POLYBENCH_ROOT}
DATASET=${2:-LARGE_DATASET}
RUNS=${3:-30}
OUT_RAW=${4:-$REPORTS_DIR/polybench_overhead_extra4_raw.tsv}
OUT_SUMMARY=${5:-$REPORTS_DIR/polybench_overhead_extra4_summary.tsv}

ensure_dir "$(dirname "$OUT_RAW")"
ensure_dir "$(dirname "$OUT_SUMMARY")"

benches=(
  "atax linear-algebra/kernels/atax/atax"
  "mvt linear-algebra/kernels/mvt/mvt"
  "syr2k linear-algebra/blas/syr2k/syr2k"
  "seidel-2d stencils/seidel-2d/seidel-2d"
)

tmpdir=$(mktemp -d /tmp/polybench-suite-extra4.XXXXXX)
trap 'rm -rf "$tmpdir"' EXIT

{
  echo -e "bench\tvariant\trun\tseconds\tmax_rss_kb"
  for item in "${benches[@]}"; do
    name=${item%% *}
    rel=${item#* }
    prefix="$tmpdir/${name}"
    "$SCRIPT_DIR/build_polybench_variants.sh" "$ROOT" "$rel" "$DATASET" "$prefix" >/dev/null
    "$SCRIPT_DIR/run_polybench_overhead.sh" "$name" "${prefix}.off.wasm" "${prefix}.on.wasm" "${prefix}.mem1.wasm" "$RUNS" | tail -n +2
  done
} >"$OUT_RAW"

{
  printf "bench\tvariant\tmean_seconds\tstd_seconds\tmean_max_rss_kb\tstd_max_rss_kb\truns\n"
awk -F'\t' '
BEGIN { OFS="\t" }
NR>1 {
  key=$1 OFS $2
  sec[key]+=$4
  sec2[key]+=($4*$4)
  rss[key]+=$5
  rss2[key]+=($5*$5)
  n[key]++
}
END {
  for (k in n) {
    split(k, a, OFS)
    mean_sec=sec[k]/n[k]
    mean_rss=rss[k]/n[k]
    std_sec=(n[k] > 1) ? sqrt((sec2[k]/n[k]) - (mean_sec*mean_sec)) : 0
    std_rss=(n[k] > 1) ? sqrt((rss2[k]/n[k]) - (mean_rss*mean_rss)) : 0
    printf "%s\t%s\t%.4f\t%.4f\t%.1f\t%.1f\t%d\n", a[1], a[2], mean_sec, std_sec, mean_rss, std_rss, n[k]
  }
}' "$OUT_RAW" | sort
} >"$OUT_SUMMARY"

echo "Wrote $OUT_RAW"
echo "Wrote $OUT_SUMMARY"
column -t -s $'\t' "$OUT_SUMMARY"
