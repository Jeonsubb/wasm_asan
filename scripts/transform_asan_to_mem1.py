#!/usr/bin/env python3
import re
import sys
from pathlib import Path

TARGET_EXACT = {
    "$__asan_load1",
    "$__asan_load2",
    "$__asan_load4",
    "$__asan_load8",
    "$__asan_load16",
    "$__asan_store1",
    "$__asan_store2",
    "$__asan_store4",
    "$__asan_store8",
    "$__asan_store16",
    "$__asan_poison_memory_region",
    "$__asan_unpoison_memory_region",
    "$__asan_address_is_poisoned",
    "$__asan_region_is_poisoned",
    "$__asan_poison_stack_memory",
    "$__asan_unpoison_stack_memory",
    "$__asan_set_shadow_00",
    "$__asan_set_shadow_f1",
    "$__asan_set_shadow_f2",
    "$__asan_set_shadow_f3",
    "$__asan_set_shadow_f5",
    "$__asan_set_shadow_f8",
    "$__asan::PoisonShadow_unsigned_long__unsigned_long__unsigned_char_",
    "$__asan_register_globals",
    "$__asan_unregister_globals",
}

TARGET_PREFIXES = (
    "$__asan_load",
    "$__asan_store",
    "$asan_c_load_",
    "$asan_c_store_",
)

FUNC_START_RE = re.compile(r"^\s*\(func\s+(\$[^\s\)]+)")


def in_target(name: str) -> bool:
    if name in TARGET_EXACT:
        return True
    if name.startswith("$__asan::ErrorGeneric::ErrorGeneric_"):
        return True
    if name == "$__asan::ErrorGeneric::Print__":
        return True
    # Fallback for variant mangling in some builds
    return name.startswith(TARGET_PREFIXES)


def add_mem1_to_op(line: str, op: str) -> str:
    # only patch plain op forms not already memory-indexed
    patt = re.compile(rf"\b{re.escape(op)}\b(?!\s*\(memory\s+)")
    return patt.sub(f"{op} (memory 1)", line)


def compact_rewrite_mem1_ops(line: str) -> str:
    replacements = {
        'i32.load8_u (memory 1)': 'call $__mem1_load8_u',
        'i32.load8_s (memory 1)': 'call $__mem1_load8_s',
        'i32.store8 (memory 1)': 'call $__mem1_store8',
        'i32.store16 (memory 1)': 'call $__mem1_store16',
        'i32.store (memory 1)': 'call $__mem1_store32',
    }
    for old, new in replacements.items():
        if old in line:
            return line.replace(old, new)
    return line


def rewrite_target_line(current_func: str, line: str, state: dict[str, int]) -> str:
    patched = line

    if current_func == "$__asan_shadow_load8":
        if "i32.load8_u" in patched and "offset=" not in patched:
            patched = add_mem1_to_op(patched, "i32.load8_u")
        return patched

    if current_func == "$__asan_shadow_store8":
        if "i32.store8" in patched and "offset=" not in patched:
            patched = add_mem1_to_op(patched, "i32.store8")
        return patched

    if current_func == "$__asan_shadow_store16":
        if "i32.store16" in patched and "offset=" not in patched:
            patched = add_mem1_to_op(patched, "i32.store16")
        return patched

    if current_func == "$__asan_shadow_store32":
        if re.search(r"\bi32\.store\b", patched) and "offset=" not in patched:
            patched = add_mem1_to_op(patched, "i32.store")
        return patched

    if current_func.startswith("$asan_c_"):
        # In the C ABI wrappers, the first plain byte load is the shadow read.
        # Later byte loads/stores are the real application access and must stay on mem0.
        if "offset=" not in patched:
            for op in ("i32.load8_s", "i32.load8_u"):
                if op in patched and state.get("asan_c_shadow_load_rewritten", 0) == 0:
                    patched = add_mem1_to_op(patched, op)
                    state["asan_c_shadow_load_rewritten"] = 1
                    return patched
        return patched

    if current_func in {"$__asan_register_globals", "$__asan_unregister_globals"}:
        patched = patched.replace("call $emscripten_builtin_memset", "call $__mem1_memset")
        if "i32.store8" in patched and "offset=" not in patched:
            patched = add_mem1_to_op(patched, "i32.store8")
        return patched

    if current_func.startswith("$__asan::ErrorGeneric::ErrorGeneric_"):
        if "offset=" not in patched:
            for op in ("i32.load8_s", "i32.load8_u"):
                if op in patched:
                    patched = add_mem1_to_op(patched, op)
        return patched

    if current_func == "$__asan::ErrorGeneric::Print__":
        if "i32.load8_u" in patched and "offset=" not in patched:
            patched = add_mem1_to_op(patched, "i32.load8_u")
        return patched

    # Fixed-offset loads in ASan runtime read config/global data, not shadow bytes.
    if "offset=" not in patched:
        for op in ("i32.load8_s", "i32.load8_u", "i32.store8"):
            patched = add_mem1_to_op(patched, op)
    patched = patched.replace("call $emscripten_builtin_memset", "call $__mem1_memset")
    return patched


def main() -> int:
    if len(sys.argv) < 3 or len(sys.argv) > 5:
      print("Usage: transform_asan_to_mem1.py <input.wat> <output.wat> [--no-selftest] [--compact-mem1]", file=sys.stderr)
      return 2

    inject_selftest = True
    compact_mem1 = False
    for opt in sys.argv[3:]:
        if opt == "--no-selftest":
            inject_selftest = False
        elif opt == "--compact-mem1":
            compact_mem1 = True
        else:
            print("unknown option: " + opt, file=sys.stderr)
            return 2

    src = Path(sys.argv[1]).read_text(encoding="utf-8")
    lines = src.splitlines()

    out = []
    current_func = None
    inserted_mem1 = False
    func_state: dict[str, int] = {}

    for line in lines:
        m = FUNC_START_RE.match(line)
        if m:
            current_func = m.group(1)
            func_state = {}

        # Insert secondary memory right after primary memory declaration.
        if not inserted_mem1 and re.match(r"^\s*\(memory\s+\(;0;\)\s+\d+\s+\d+\)\s*$", line):
            out.append(line)
            mem_decl = re.sub(r"\(;0;\)", "(;1;)", line)
            if compact_mem1:
                nums = [int(x) for x in re.findall(r"\b\d+\b", line)]
                if len(nums) >= 3:
                    wasm_page = 65536
                    init_pages = nums[-2]
                    max_pages = nums[-1]
                    user_mem = max_pages * wasm_page if max_pages > init_pages else init_pages * wasm_page
                    total_mem = ((user_mem * 8 // 7) + wasm_page - 1) // wasm_page * wasm_page
                    shadow_size = total_mem // 8
                    compact_shadow_base = shadow_size // 8
                    init_total_bytes = init_pages * wasm_page
                    app_initial_bytes = max(0, init_total_bytes - shadow_size)
                    compact_init_bytes = ((max(1, (app_initial_bytes + 7) // 8)) + wasm_page - 1) // wasm_page * wasm_page
                    compact_max_bytes = ((max(1, (user_mem + 7) // 8)) + wasm_page - 1) // wasm_page * wasm_page
                    compact_init = compact_init_bytes // wasm_page
                    compact_max = max(compact_init, compact_max_bytes // wasm_page)
                    mem_decl = re.sub(r"\)\s+\d+\s+\d+\)\s*$",
                                      f") {compact_init} {compact_max})",
                                      mem_decl)
            out.append(mem_decl)
            inserted_mem1 = True
            continue

        if current_func and (
            in_target(current_func)
            or current_func in {
                "$__asan_shadow_load8",
                "$__asan_shadow_store8",
                "$__asan_shadow_store16",
                "$__asan_shadow_store32",
            }
        ):
            rewritten = rewrite_target_line(current_func, line, func_state)
        else:
            rewritten = line

        if compact_mem1:
            rewritten = compact_rewrite_mem1_ops(rewritten)

        out.append(rewritten)

        # function end heuristic: line ending with ')' while in func body is enough for this generated WAT
        if current_func and line.strip().endswith(")"):
            # do not try exact nesting parse; keep function context until next func start is also acceptable.
            pass

    if not inserted_mem1:
        print("Could not find (memory (;0;) ...) declaration to insert mem1", file=sys.stderr)
        return 1

    compact_helper = []
    if compact_mem1:
        compact_shadow_base = compact_shadow_base if 'compact_shadow_base' in locals() else 0
        compact_helper = [
            "  (func $__mem1_rebase (param $addr i32) (result i32)",
            "    local.get $addr",
            f"    i32.const {shadow_size}",
            "    i32.ge_u",
            "    if (result i32)",
            "      local.get $addr",
            "      i32.const 3",
            "      i32.shr_u",
            "    else",
            "      local.get $addr",
            "    end",
            f"    i32.const {compact_shadow_base}",
            "    i32.sub)",
            "  (func $__mem1_ensure_end (param $end i32)",
            "    (local $need i32)",
            "    (local $cur i32)",
            "    local.get $end",
            "    i32.const 65535",
            "    i32.add",
            "    i32.const 16",
            "    i32.shr_u",
            "    local.tee $need",
            "    memory.size (memory 1)",
            "    local.tee $cur",
            "    i32.gt_u",
            "    if",
            "      local.get $need",
            "      local.get $cur",
            "      i32.sub",
            "      memory.grow (memory 1)",
            "      drop",
            "    end)",
            "  (func $__mem1_load8_u (param $addr i32) (result i32)",
            "    (local $idx i32)",
            "    local.get $addr",
            "    call $__mem1_rebase",
            "    local.set $idx",
            "    local.get $idx",
            "    i32.const 1",
            "    i32.add",
            "    call $__mem1_ensure_end",
            "    local.get $idx",
            "    i32.load8_u (memory 1))",
            "  (func $__mem1_load8_s (param $addr i32) (result i32)",
            "    (local $idx i32)",
            "    local.get $addr",
            "    call $__mem1_rebase",
            "    local.set $idx",
            "    local.get $idx",
            "    i32.const 1",
            "    i32.add",
            "    call $__mem1_ensure_end",
            "    local.get $idx",
            "    i32.load8_s (memory 1))",
            "  (func $__mem1_store8 (param $addr i32) (param $val i32)",
            "    (local $idx i32)",
            "    local.get $addr",
            "    call $__mem1_rebase",
            "    local.set $idx",
            "    local.get $idx",
            "    i32.const 1",
            "    i32.add",
            "    call $__mem1_ensure_end",
            "    local.get $idx",
            "    local.get $val",
            "    i32.store8 (memory 1))",
            "  (func $__mem1_store16 (param $addr i32) (param $val i32)",
            "    (local $idx i32)",
            "    local.get $addr",
            "    call $__mem1_rebase",
            "    local.set $idx",
            "    local.get $idx",
            "    i32.const 2",
            "    i32.add",
            "    call $__mem1_ensure_end",
            "    local.get $idx",
            "    local.get $val",
            "    i32.store16 (memory 1))",
            "  (func $__mem1_store32 (param $addr i32) (param $val i32)",
            "    (local $idx i32)",
            "    local.get $addr",
            "    call $__mem1_rebase",
            "    local.set $idx",
            "    local.get $idx",
            "    i32.const 4",
            "    i32.add",
            "    call $__mem1_ensure_end",
            "    local.get $idx",
            "    local.get $val",
            "    i32.store (memory 1))",
        ]

    memset_helper = [
        "  (func $__mem1_memset (param $dst i32) (param $val i32) (param $len i32) (result i32)",
        "    (local $i i32)",
        "    (local $ret i32)",
        "    local.get $dst",
        "    local.set $ret",
    ]
    if compact_mem1:
        memset_helper += [
            "    local.get $dst",
            "    call $__mem1_rebase",
            "    local.set $dst",
            "    local.get $dst",
            "    local.get $len",
            "    i32.add",
            "    call $__mem1_ensure_end",
        ]
    memset_helper += [
        "    i32.const 0",
        "    local.set $i",
        "    block $done",
        "      loop $loop",
        "        local.get $i",
        "        local.get $len",
        "        i32.ge_u",
        "        br_if $done",
        "        local.get $dst",
        "        local.get $i",
        "        i32.add",
        "        local.get $val",
        "        i32.store8 (memory 1)",
        "        local.get $i",
        "        i32.const 1",
        "        i32.add",
        "        local.set $i",
        "        br $loop",
        "      end",
        "    end",
        "    local.get $ret)",
    ]

    helper = compact_helper + memset_helper + [
        "  (func (export \"mem1_test_poison\") (param $shadow_addr i32) (param $len i32)",
        "    local.get $shadow_addr",
        "    local.get $len",
        "    call $__asan_set_shadow_f1)",
        "  (func (export \"mem1_test_unpoison\") (param $shadow_addr i32) (param $len i32)",
        "    local.get $shadow_addr",
        "    local.get $len",
        "    call $__asan_set_shadow_00)",
        "  (func (export \"mem1_test_is_poisoned\") (param $addr i32) (result i32)",
        "    local.get $addr",
        "    call $__asan_address_is_poisoned)",
        "  (func (export \"mem1_test_poke_mem0_shadow_like\") (param $addr i32) (param $tag i32)",
        "    local.get $addr",
        "    i32.const 3",
        "    i32.shr_u",
        "    local.get $tag",
        "    i32.store8 (memory 0))",
        "  (func (export \"mem1_test_peek_mem1_shadow\") (param $addr i32) (result i32)",
        "    local.get $addr",
        "    i32.const 3",
        "    i32.shr_u",
        "    i32.load8_u (memory 1))",
        "  (func (export \"mem1_selftest\") (result i32)",
        "    (local $addr i32)",
        "    (local $saddr i32)",
        "    (local $before i32)",
        "    (local $after i32)",
        "    (local $pois i32)",
        "    i32.const 306790400",
        "    local.set $addr",
        "    local.get $addr",
        "    i32.const 3",
        "    i32.shr_u",
        "    local.set $saddr",
        "    local.get $saddr",
        "    i32.const 1",
        "    call $__asan_set_shadow_00",
        "    local.get $saddr",
        "    i32.const 1",
        "    call $__asan_set_shadow_f1",
        "    local.get $addr",
        "    i32.const 3",
        "    i32.shr_u",
        "    i32.load8_u (memory 1)",
        "    local.set $before",
        "    local.get $addr",
        "    i32.const 3",
        "    i32.shr_u",
        "    i32.const 0",
        "    i32.store8 (memory 0)",
        "    local.get $addr",
        "    i32.const 3",
        "    i32.shr_u",
        "    i32.load8_u (memory 1)",
        "    local.set $after",
        "    local.get $addr",
        "    call $__asan_address_is_poisoned",
        "    local.set $pois",
        "    local.get $before",
        "    i32.const 16",
        "    i32.shl",
        "    local.get $after",
        "    i32.const 8",
        "    i32.shl",
        "    i32.or",
        "    local.get $pois",
        "    i32.or)",
    ]

    if not inject_selftest:
        # Drop only the exported self-test helpers while keeping the full
        # internal memset helper body intact, regardless of whether compact
        # mem1 helpers were prepended above.
        marker = "  (func (export \"mem1_test_poison\") (param $shadow_addr i32) (param $len i32)"
        if marker in helper:
            helper = helper[:helper.index(marker)]

    # Inject helper before module close
    out_text = "\n".join(out) + "\n"
    helper_text = "\n".join(helper) + "\n"
    m = re.search(r"\)\s*$", out_text, flags=re.S)
    if not m:
        print("Unexpected WAT trailer: module close not found", file=sys.stderr)
        return 1
    insert_at = m.start()
    out_text = out_text[:insert_at] + helper_text + out_text[insert_at:]
    Path(sys.argv[2]).write_text(out_text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
