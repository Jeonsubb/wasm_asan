# Runtime-Aware Rebase Pass Checklist

## Goal

Reclaim the inflated `mem0` layout left by single-memory Wasm ASan after
moving shadow metadata into `mem1`, so that:

1. `mem0` no longer reserves the original low-shadow region.
2. `GLOBAL_BASE`, data segments, stack, and heap move forward accordingly.
3. The linked ASan runtime continues to work with the reclaimed layout.
4. Total memory overhead is reduced, not just `mem1` footprint.

## What We Already Achieved

### Implemented

1. `mem1` shadow isolation.
2. Compact shadow mapping for `mem1`.
3. `mem1` growth on demand.
4. Reclaimed `mem0` layout at the binary/WAT level:
   - `memory0: 5706/32768 -> 1025/28087 pages`
5. Direct shadow-tampering bypass is blocked in `mem1`.

### Honest Current Limitation

The reclaimed layout is not yet end-to-end stable because the linked ASan
runtime still contains additional single-memory assumptions beyond raw memory
layout.

This means the current memory-overhead contribution should be stated as:

- `mem1` shadow footprint reduction: demonstrated
- `mem0` inflated-layout reclamation: partially implemented, runtime-complete
  support still in progress

## Why Another Pass Is Needed

`asan_shadow_abstraction_pass.cpp` handles instrumentation-side shadow access
abstraction. It does not fully rewrite the linked ASan runtime.

The remaining problem is post-link:

1. runtime functions still assume low shadow exists inside `mem0`
2. runtime code still embeds layout-dependent constants
3. bulk poison/unpoison paths may still use the old single-memory mapping

Therefore, the next step is a separate post-link pass:

- `runtime-aware rebase pass`

## Target Functions To Patch

### Tier 1: Mandatory

These must be made compatible with reclaimed `mem0` + compact `mem1`.

1. `__asan::InitializeShadowMemory__`
   - Remove low-shadow-in-`mem0` assumptions
   - Replace with mem1-aware init or no-op if redundant

2. `__asan_register_globals`
3. `__asan_unregister_globals`
   - Ensure global redzone poisoning uses compact `mem1` mapping

4. `__asan_poison_memory_region`
5. `__asan_unpoison_memory_region`
6. stack/global poison helpers
   - All poisoning must target compact `mem1`

7. `__asan_address_is_poisoned`
   - Must use reclaimed mapping and compact `mem1`

### Tier 2: Report / Diagnostics

8. `__asan::ErrorGeneric::*`
   - Shadow lookup for reports must use compact `mem1`

9. shadow dump / legend printing helpers
   - Avoid old low-shadow assumptions

### Tier 3: Allocation / Runtime Init

10. allocator-related poison/unpoison paths
11. startup paths that compute shadow bounds
12. any helper that still compares against old low-shadow constants

## Rewrite Rules

### Rule A: Layout Rebase

Apply `delta = old_first_data_offset - new_first_data_offset`.

Shift by `-delta` for:

1. `memory 0` init/max page sizing
2. `__stack_pointer`
3. `__heap_base`
4. `__data_end`
5. all active data-segment offsets
6. embedded pointers in `.data` / runtime tables
7. layout-dependent `i32.const` / `offset=` immediates that reference static
   `mem0` addresses

### Rule B: Compact Shadow Mapping

Replace the old mapping assumption:

`shadow = addr >> 3`

with compact `mem1` indexing:

`shadow_idx = max(0, (addr >> 3) - compact_shadow_base)`

Where:

- `compact_shadow_base = new_GLOBAL_BASE >> 3`

Requirements:

1. low-address inputs must not underflow
2. `mem1` growth must happen before bulk writes / long shadow ranges
3. all shadow accesses must resolve through the same compact rule

### Rule C: Runtime Semantic Rewrite

If a runtime function still assumes:

1. low shadow lives in `mem0`
2. shadow starts at address 0 in `mem0`
3. shadow size must fit inside old `kLowShadowEnd`

then:

1. remove the assertion/check, or
2. replace it with a compact-`mem1` equivalent

## Recommended Implementation Order

### Phase 1: Make reclaimed layout boot cleanly

1. Patch startup/runtime init until `_start` no longer hangs/traps
2. Validate:
   - `global_oob`
   - `heap_oob`
   - `exploit_global_shadow_unpoison`

### Phase 2: Re-establish functional equivalence

3. Re-run feature matrix on reclaimed build:
   - `heap_oob`
   - `stack_oob`
   - `global_oob`
   - `use_after_free`
   - `double_free`
   - `invalid_free`
   - `use_after_scope`
   - `leak`
   - `container_overflow`

### Phase 3: Re-measure memory overhead

4. Compare against baseline single-memory ASan:
   - `mem0_init_pages`
   - `mem0_max_pages`
   - `first_data_offset`
   - peak RSS
   - PolyBench runtime

## Paper Wording

## Safe Wording Right Now

Use this if reclaimed `mem0` is not yet end-to-end complete:

"We demonstrated that shadow metadata can be compacted in `mem1`, reducing the
shadow-memory footprint substantially. In addition, we implemented a prototype
mem0-layout reclamation pass that reduces the inflated application-memory
reservation introduced by single-memory Wasm ASan, although full runtime
compatibility still requires additional rewriting of linked ASan runtime paths."

## Stronger Wording Once Reclaimed Build Works End-to-End

"Beyond integrity isolation, our multi-memory design reduces memory overhead by
both compacting shadow metadata in `mem1` and reclaiming the inflated `mem0`
layout left by the original single-memory Wasm ASan design."

## Contribution Framing

Even before full reclaimed-layout completion, it is accurate to claim:

1. integrity improvement through shadow isolation
2. shadow-memory footprint reduction through compact `mem1`
3. experimental evidence that full application-layout reclamation is feasible
   but requires a runtime-aware rebase pass

This is stronger and more honest than claiming total memory-overhead reduction
has already been fully solved.
