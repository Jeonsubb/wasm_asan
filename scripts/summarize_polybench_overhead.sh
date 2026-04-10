#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

IN=${1:-$REPORTS_DIR/polybench_overhead_summary.tsv}

{
  printf "bench\ton_vs_off_time\tmem1_vs_off_time\tmem1_vs_on_time\ton_vs_off_rss\tmem1_vs_off_rss\tmem1_vs_on_rss\n"
  awk -F'\t' '
  NR==1 { next }
  {
    sec[$1,$2]=$3
    rss[$1,$2]=$5
    bench[$1]=1
  }
  END {
    for (b in bench) {
      printf "%s\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\n", \
        b, sec[b,"on"]/sec[b,"off"], sec[b,"mem1"]/sec[b,"off"], sec[b,"mem1"]/sec[b,"on"], \
        rss[b,"on"]/rss[b,"off"], rss[b,"mem1"]/rss[b,"off"], rss[b,"mem1"]/rss[b,"on"]
    }
  }' "$IN" | sort
}
