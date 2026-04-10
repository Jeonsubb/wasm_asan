# Wasm ASan Shadow Isolation

> WebAssembly AddressSanitizer의 shadow memory를 `memory 1`로 분리해  
> 프로그램 메모리(`mem0`)와 메타데이터(shadow)의 무결성을 더 강하게 지키는 실험 프로젝트입니다.

## 프로젝트 소개

이 저장소는 Emscripten/LLVM 기반 Wasm AddressSanitizer를 그대로 활용하면서, shadow memory 접근만 `memory 1`로 리디렉션하는 실험 파이프라인을 구현한 프로젝트입니다.  
핵심 목표는 "기존 ASan의 탐지 행위를 최대한 유지하면서도, 단일 메모리 구조에서 가능한 shadow 오염 가능성을 구조적으로 줄일 수 있는가?"를 검증하는 것입니다.

단순히 아이디어를 적어둔 수준이 아니라, 실제로 아래 흐름까지 재현할 수 있게 정리했습니다.

- LLVM pass로 인라인 shadow 접근을 helper 호출로 추상화
- WAT rewrite 단계에서 shadow 관련 load/store를 `memory 1`로 이동
- baseline ASan과 mem1 ASan의 동작 등가성 비교 자동화
- compact mem1 변형과 PolyBench 벤치마크 실험 스크립트 제공
- mini PoC로 single-memory 대비 multi-memory 분리 효과 시각화

## 왜 이 프로젝트가 흥미로운가

- 보안 관점: shadow metadata를 애플리케이션 메모리와 물리적으로 분리하는 실험입니다.
- 컴파일러 관점: C/C++ → LLVM IR → wasm/wat 단계까지 여러 층을 직접 연결합니다.
- 엔지니어링 관점: 아이디어 설명이 아니라, 재현 가능한 스크립트와 비교 리포트까지 갖춘 형태입니다.
- 포트폴리오 관점: 시스템/컴파일러/보안/성능 측정을 한 저장소 안에서 보여줄 수 있습니다.

## 핵심 구현 포인트

1. `passes/asan_mem1_pass`
   인라인 ASan shadow 접근을 `__asan_shadow_load8`, `__asan_shadow_store*` helper 호출로 치환하는 LLVM pass가 들어 있습니다.

2. `scripts/transform_asan_to_mem1.py`
   생성된 WAT에서 shadow 관련 연산만 골라 `memory 1`로 리디렉션합니다.

3. `scripts/build_mem1_asan_inline.sh`
   inline ASan 계측을 유지한 채 mem1 버전을 생성하는 메인 빌드 파이프라인입니다.

4. `scripts/verify_mem1_equivalence.sh`
   `heap_oob`, `stack_oob`, `global_oob`, `use_after_free` 등 주요 케이스에서 baseline ASan과 mem1 ASan의 행위를 비교합니다.

5. `scripts/run_polybench_suite*.sh`
   PolyBench 워크로드를 대상으로 실행 시간과 RSS 오버헤드를 반복 측정합니다.

## 디렉터리 구조

```text
.
├── README.md
├── docs/                  # 실험 노트, 비교 결과 요약
├── scripts/               # 빌드/검증/벤치/변환 스크립트
├── src/                   # 실험용 C/C++ 소스와 WAT 템플릿
├── passes/asan_mem1_pass/ # LLVM pass 구현
├── third_party/           # PolyBench 원본
└── artifacts/             # 생성 산출물(로컬 보관, git ignore)
```

`artifacts/` 아래에는 빌드 결과물과 리포트가 쌓이도록 정리했습니다.

## 빠른 시작

### 1) mem1 ASan 빌드

```bash
./scripts/build_mem1_asan.sh
```

기본 생성물:

- `artifacts/generated/asan_mem1_calls.wasm`
- `artifacts/generated/asan_mem1_mem1.wasm`

### 2) self-test 실행

```bash
./scripts/test_mem1_asan.sh
```

### 3) baseline ASan vs mem1 ASan 등가성 확인

```bash
./scripts/verify_mem1_equivalence.sh
```

### 4) mini PoC 실행

```bash
./scripts/run_mini_asan_poc.sh
```

기대 관찰:

- single-memory에서는 shadow 값이 변조될 수 있음
- multi-memory에서는 shadow 값이 유지됨

### 5) PolyBench 오버헤드 측정

```bash
./scripts/run_polybench_suite.sh
./scripts/summarize_polybench_overhead.sh > artifacts/reports/polybench_overhead_ratios.tsv
```

## 추천 확인 포인트

- `./scripts/verify_mem1_equivalence.sh`
  baseline ASan과 mem1 ASan의 에러 타입이 얼마나 일치하는지 보기 좋습니다.

- `./scripts/compare_asan_behaviors.sh`
  주요 동작 매트릭스를 `docs/asan_behavior_matrix.md`로 다시 생성할 수 있습니다.

- `./scripts/compare_asan_compact_behaviors.sh`
  compact mem1 변형의 동작 보존 여부를 확인할 수 있습니다.

- `./scripts/dump_layout.sh`
  ASan 적용 전후 메모리 레이아웃 차이를 덤프합니다.

## 문서

- [재현 가이드](./docs/build_run.md)
- [ASan 동작 비교 표](./docs/asan_behavior_matrix.md)
- [Compact mem1 비교 표](./docs/asan_compact_behavior_matrix.md)
- [선택 기능 비교](./docs/asan_optional_features.md)

## 이 저장소가 보여주는 역량

- LLVM pass 작성과 IR 수준 변환 설계
- Wasm/WAT 수준 메모리 재배치 및 runtime 적응
- 보안 가설을 실험 가능한 코드와 리포트로 연결하는 능력
- 성능 측정 자동화와 결과 구조화

논문 초안용 실험 저장소이면서도, 포트폴리오 관점에서 봐도 "아이디어, 구현, 검증"이 한 번에 보이도록 다듬은 버전입니다.
