#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

IN=${1:-$REPORTS_DIR/polybench_overhead_raw_100x.tsv}
SKIP=${2:-10}
OUT=${3:-$REPORTS_DIR/polybench_overhead_summary_100x_trimmed.tsv}

ensure_dir "$(dirname "$OUT")"

{
  printf "bench\tvariant\tmean_seconds\tstd_seconds\tmean_max_rss_kb\tstd_max_rss_kb\truns_used\twarmup_skipped\n"
  awk -F'\t' -v skip="$SKIP" '
  BEGIN { OFS="\t" }
  NR==1 { next }
  $1 == "" { next }
  {
    if ($3 <= skip) next
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
      printf "%s\t%s\t%.4f\t%.4f\t%.1f\t%.1f\t%d\t%d\n", a[1], a[2], mean_sec, std_sec, mean_rss, std_rss, n[k], skip
    }
  }' "$IN" | sort
} > "$OUT"

cat "$OUT"
