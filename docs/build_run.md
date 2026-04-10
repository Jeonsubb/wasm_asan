# Wasm ASan 실험 가이드

루트 정리 이후 기준으로, 이 저장소의 기본 진입점은 모두 `./scripts/...` 아래에 있습니다.  
생성 산출물은 기본적으로 `artifacts/` 아래에 쌓이며, 소스는 `src/`, LLVM pass는 `passes/asan_mem1_pass/`에 정리되어 있습니다.

## 1) 가장 빠른 재현 경로

### mem1 빌드

```bash
./scripts/build_mem1_asan.sh
```

기본 생성물:

- `artifacts/generated/asan_mem1_calls.wasm`
- `artifacts/generated/asan_mem1_calls.wat`
- `artifacts/generated/asan_mem1_mem1.wasm`
- `artifacts/generated/asan_mem1_mem1.wat`

### self-test

```bash
./scripts/test_mem1_asan.sh
```

### baseline vs mem1 등가성 확인

```bash
./scripts/verify_mem1_equivalence.sh
```

## 2) 인라인 ASan 계측 경로

inline instrumentation을 유지한 채 shadow 접근을 helper call로 추상화하고, 이후 `memory 1` 리디렉션까지 이어지는 실험 흐름입니다.

```bash
./scripts/apply_asan_shadow_abstraction.sh
./scripts/build_mem1_asan_inline.sh
./scripts/test_mem1_asan.sh artifacts/generated/asan_inline_mem1.mem1.wasm
```

핵심 파일:

- `passes/asan_mem1_pass/asan_shadow_abstraction_pass.cpp`
- `src/asan_shadow_hooks.c`
- `scripts/transform_asan_to_mem1.py`

## 3) 런타임 실행

### Node WASI runner

```bash
node ./scripts/run_wasi.js artifacts/generated/asan_on.wasm heap_oob
node ./scripts/run_wasi.js artifacts/generated/asan_on.wasm stack_oob
node ./scripts/run_wasi.js artifacts/generated/asan_on.wasm global_oob
```

### wasmtime 실행

`./scripts/run_with_wasmtime.sh`는 `artifacts/generated/env_stub_asan.wasm`이 없으면 자동으로 생성합니다.

```bash
./scripts/run_with_wasmtime.sh artifacts/generated/asan_on.wasm heap_oob
./scripts/run_with_wasmtime.sh artifacts/generated/asan_on.wasm stack_oob
./scripts/run_with_wasmtime.sh artifacts/generated/asan_on.wasm global_oob
```

## 4) mini PoC

single-memory와 multi-memory의 shadow 무결성 차이를 빠르게 확인할 수 있습니다.

```bash
./scripts/run_mini_asan_poc.sh
```

기대 관찰:

- single-memory: shadow 값이 변할 수 있음
- multi-memory: shadow 값이 유지됨

## 5) 레이아웃/행위 비교

### 메모리 레이아웃 덤프

```bash
./scripts/dump_layout.sh
```

출력 위치:

- `artifacts/layout/ASAN_OFF.objdump.txt`
- `artifacts/layout/ASAN_OFF.wat`
- `artifacts/layout/ASAN_ON.objdump.txt`
- `artifacts/layout/ASAN_ON.wat`

### 동작 비교 표 생성

```bash
./scripts/compare_asan_behaviors.sh
./scripts/compare_asan_compact_behaviors.sh
./scripts/compare_asan_optional_features.sh
```

문서 갱신 위치:

- `docs/asan_behavior_matrix.md`
- `docs/asan_compact_behavior_matrix.md`
- `docs/asan_optional_features.md`

## 6) PolyBench 측정

```bash
./scripts/run_polybench_suite.sh
./scripts/run_polybench_suite_extended.sh
./scripts/run_polybench_suite_extra4.sh
./scripts/run_polybench_suite_remaining2.sh
```

요약 보조 스크립트:

```bash
./scripts/summarize_polybench_overhead.sh > artifacts/reports/polybench_overhead_ratios.tsv
./scripts/summarize_polybench_trimmed.sh
./scripts/summarize_polybench_trimmed_ratios.sh > artifacts/reports/polybench_trimmed_ratios.tsv
```

기본 리포트 저장 위치:

- `artifacts/reports/*.tsv`

## 7) 추천 확인 순서

1. `./scripts/build_mem1_asan.sh`
2. `./scripts/test_mem1_asan.sh`
3. `./scripts/verify_mem1_equivalence.sh`
4. `./scripts/run_mini_asan_poc.sh`
5. `./scripts/run_polybench_suite.sh`

이 순서로 보면 아이디어, 구현, 검증, 성능 측정까지 자연스럽게 이어집니다.
