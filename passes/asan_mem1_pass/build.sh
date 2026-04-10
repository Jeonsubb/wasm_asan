#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
clang++-15 -fPIC -shared asan_shadow_abstraction_pass.cpp -o libAsanShadowAbstraction.so \
  $(llvm-config-15 --cxxflags --ldflags --system-libs --libs core passes)
echo "built $(pwd)/libAsanShadowAbstraction.so"
