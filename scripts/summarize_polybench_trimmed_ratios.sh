#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

IN=${1:-$REPORTS_DIR/polybench_overhead_summary_100x_trimmed.tsv}

python3 - "$IN" <<'PY'
import csv
import sys

path = sys.argv[1]
data = {}
with open(path, newline='') as f:
    r = csv.DictReader(f, delimiter='\t')
    for row in r:
        bench = row['bench']
        variant = row['variant']
        data.setdefault(bench, {})[variant] = row

print("bench\ton_vs_off_time\tmem1_vs_off_time\tmem1_vs_on_time\ton_vs_off_rss\tmem1_vs_off_rss\tmem1_vs_on_rss")
for bench in sorted(data):
    d = data[bench]
    off_t = float(d['off']['mean_seconds'])
    on_t = float(d['on']['mean_seconds'])
    mem1_t = float(d['mem1']['mean_seconds'])
    off_r = float(d['off']['mean_max_rss_kb'])
    on_r = float(d['on']['mean_max_rss_kb'])
    mem1_r = float(d['mem1']['mean_max_rss_kb'])
    print(f"{bench}\t{on_t/off_t:.3f}\t{mem1_t/off_t:.3f}\t{mem1_t/on_t:.3f}\t{on_r/off_r:.3f}\t{mem1_r/off_r:.3f}\t{mem1_r/on_r:.3f}")
PY
