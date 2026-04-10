#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname "$0")" && pwd)
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

OFF_WASM=${1:-$GENERATED_DIR/asan_off.wasm}
ON_WASM=${2:-$GENERATED_DIR/asan_on.wasm}
OUT_DIR=${3:-$LAYOUT_DIR}
mkdir -p "$OUT_DIR"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }
}

need_cmd wasm-objdump
need_cmd wasm2wat
need_cmd awk
need_cmd grep

extract_symbol() {
  local objdump_txt=$1
  local sym=$2
  awk -v s="$sym" '
    /Global\[/ {
      if ($0 ~ "<" s ">") {
        # ex) - global[0] i32 mutable=0 <__stack_pointer> - init i32=5243920
        if (match($0, /i32=([0-9]+)/, m)) {
          print m[1]
          exit
        }
      }
    }
    /Export\[/ {
      # exported globals may appear without init in this section, ignore
    }
    END { }
  ' "$objdump_txt"
}

extract_stack_pointer_init() {
  local objdump_txt=$1
  awk '
    /global\[0\] i32 mutable=1 <__stack_pointer> - init i32=/ {
      if (match($0, /i32=([0-9]+)/, m)) {
        print m[1]
        exit
      }
    }
  ' "$objdump_txt"
}

extract_initial_pages() {
  local objdump_txt=$1
  awk '
    /memory\[0\] pages: initial=/ {
      if (match($0, /initial=([0-9]+)/, m)) {
        print m[1]
        exit
      }
    }
  ' "$objdump_txt"
}

extract_first_data_offset_from_wat() {
  local wat=$1
  awk '
    /^\s*\(data / {
      # ex) (data (;0;) (i32.const 1024) "...")
      if (match($0, /\(i32\.const[[:space:]]+([0-9]+)/, m)) {
        print m[1]
        exit
      }
    }
  ' "$wat"
}

extract_first_n_data_offsets_from_wat() {
  local wat=$1
  local n=${2:-3}
  awk -v max_n="$n" '
    /^\s*\(data / {
      if (match($0, /\(i32\.const[[:space:]]+([0-9]+)/, m)) {
        c++
        vals[c]=m[1]
        if (c >= max_n) {
          for (i=1; i<=c; i++) {
            printf "%s%s", vals[i], (i<c?",":"")
          }
          print ""
          exit
        }
      }
    }
    END {
      if (c > 0 && c < max_n) {
        for (i=1; i<=c; i++) {
          printf "%s%s", vals[i], (i<c?",":"")
        }
        print ""
      }
    }
  ' "$wat"
}

summarize_one() {
  local label=$1
  local wasm=$2
  local od="$OUT_DIR/${label}.objdump.txt"
  local wt="$OUT_DIR/${label}.wat"

  wasm-objdump -x "$wasm" > "$od"
  wasm2wat "$wasm" > "$wt"

  local gbase heapbase dataend firstoff stackptr pages first3
  gbase=$(extract_symbol "$od" "__global_base" || true)
  heapbase=$(extract_symbol "$od" "__heap_base" || true)
  dataend=$(extract_symbol "$od" "__data_end" || true)
  firstoff=$(extract_first_data_offset_from_wat "$wt" || true)
  stackptr=$(extract_stack_pointer_init "$od" || true)
  pages=$(extract_initial_pages "$od" || true)
  first3=$(extract_first_n_data_offsets_from_wat "$wt" 3 || true)

  echo "$label|$gbase|$heapbase|$dataend|$firstoff|$stackptr|$pages|$first3"
}

if [[ ! -f "$OFF_WASM" || ! -f "$ON_WASM" ]]; then
  echo "Usage: $0 [asan_off.wasm] [asan_on.wasm] [out_dir]" >&2
  echo "Both wasm files must exist." >&2
  exit 1
fi

off_line=$(summarize_one "ASAN_OFF" "$OFF_WASM")
on_line=$(summarize_one "ASAN_ON" "$ON_WASM")

IFS='|' read -r _ off_g off_h off_d off_f off_sp off_pg off_f3 <<< "$off_line"
IFS='|' read -r _ on_g on_h on_d on_f on_sp on_pg on_f3 <<< "$on_line"

printf "ASan OFF: __global_base=%s, __heap_base=%s, __data_end=%s, first_data_offset=%s, stack_ptr_init=%s, initial_pages=%s, first3_data_offsets=[%s]\n" \
  "${off_g:-N/A}" "${off_h:-N/A}" "${off_d:-N/A}" "${off_f:-N/A}" "${off_sp:-N/A}" "${off_pg:-N/A}" "${off_f3:-N/A}"
printf "ASan ON : __global_base=%s, __heap_base=%s, __data_end=%s, first_data_offset=%s, stack_ptr_init=%s, initial_pages=%s, first3_data_offsets=[%s]\n" \
  "${on_g:-N/A}" "${on_h:-N/A}" "${on_d:-N/A}" "${on_f:-N/A}" "${on_sp:-N/A}" "${on_pg:-N/A}" "${on_f3:-N/A}"

if [[ -n "${off_g:-}" && -n "${on_g:-}" ]]; then
  awk -v a="$off_g" -v b="$on_g" 'BEGIN{printf("delta(__global_base)=%d\n", b-a)}'
fi
if [[ -n "${off_f:-}" && -n "${on_f:-}" ]]; then
  awk -v a="$off_f" -v b="$on_f" 'BEGIN{printf("delta(first_data_offset)=%d\n", b-a)}'
fi
if [[ -n "${off_sp:-}" && -n "${on_sp:-}" ]]; then
  awk -v a="$off_sp" -v b="$on_sp" 'BEGIN{printf("delta(stack_ptr_init)=%d\n", b-a)}'
fi
if [[ -n "${off_pg:-}" && -n "${on_pg:-}" ]]; then
  awk -v a="$off_pg" -v b="$on_pg" 'BEGIN{printf("delta(initial_pages)=%d\n", b-a)}'
fi

echo "Raw dumps saved under: $OUT_DIR"
