#!/usr/bin/env bash

COMMON_DIR=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$COMMON_DIR/.." && pwd)

SRC_DIR="$ROOT_DIR/src"
WAT_SRC_DIR="$SRC_DIR/wat"
PASS_DIR="$ROOT_DIR/passes/asan_mem1_pass"
DOCS_DIR="$ROOT_DIR/docs"
ARTIFACTS_DIR="$ROOT_DIR/artifacts"
GENERATED_DIR="$ARTIFACTS_DIR/generated"
REPORTS_DIR="$ARTIFACTS_DIR/reports"
LAYOUT_DIR="$ARTIFACTS_DIR/layout"
POC_DIR="$ARTIFACTS_DIR/poc"
THIRD_PARTY_DIR="$ROOT_DIR/third_party"
POLYBENCH_ROOT="$THIRD_PARTY_DIR/polybench-c/PolyBenchC-4.2.1-master"

ensure_dir() {
  mkdir -p "$1"
}

build_env_stub() {
  local out=${1:-$GENERATED_DIR/env_stub_asan.wasm}
  ensure_dir "$(dirname "$out")"
  wat2wasm "$WAT_SRC_DIR/env_stub_asan.wat" -o "$out"
  printf '%s\n' "$out"
}
