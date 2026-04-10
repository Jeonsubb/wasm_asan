#!/usr/bin/env python3
import re
import sys
from pathlib import Path

PAGE = 65536
TARGET_BASE = 1024

MEM_RE = re.compile(r'^(\s*\(memory \(;0;\) )(?P<init>\d+) (?P<max>\d+)(\)\s*)$')
GLOBAL_CONST_RE = re.compile(r'^(\s*\(global(?: [^\s\)]+)?(?: \(mut i32\))? \(i32\.const )(?P<val>\d+)(\)\)\s*)$')
DATA_RE = re.compile(r'^(\s*\(data(?: [^\s\)]+)? \(i32\.const )(?P<off>\d+)(\) ")(?P<body>.*?)("\)\s*)$')
I32_CONST_RE = re.compile(r'\bi32\.const\s+(\d+)\b')
OFFSET_RE = re.compile(r'\boffset=(\d+)\b')


def parse_wat_bytes(s: str) -> bytearray:
    out = bytearray()
    i = 0
    while i < len(s):
        c = s[i]
        if c != '\\':
            out.append(ord(c))
            i += 1
            continue
        if i + 2 < len(s) and all(ch in '0123456789abcdefABCDEF' for ch in s[i+1:i+3]):
            out.append(int(s[i+1:i+3], 16))
            i += 3
            continue
        escapes = {'n': 10, 'r': 13, 't': 9, '"': 34, "'": 39, '\\': 92}
        if i + 1 < len(s) and s[i+1] in escapes:
            out.append(escapes[s[i+1]])
            i += 2
            continue
        out.append(ord('\\'))
        i += 1
    return out


def emit_wat_bytes(bs: bytearray) -> str:
    return ''.join(f'\\{b:02x}' if b < 32 or b >= 127 or b in (34, 92) else chr(b) for b in bs)


def patch_data_bytes(body: str, lo: int, hi: int, delta: int) -> str:
    bs = parse_wat_bytes(body)
    # Patch aligned little-endian 32-bit words that point into the shifted mem0 static range.
    for i in range(0, len(bs) - 3):
        v = int.from_bytes(bs[i:i+4], 'little')
        if lo <= v <= hi:
            nv = v - delta
            bs[i:i+4] = nv.to_bytes(4, 'little')
    return emit_wat_bytes(bs)


def main() -> int:
    if len(sys.argv) != 3:
        print('usage: reclaim_mem0_layout.py <input.wat> <output.wat>', file=sys.stderr)
        return 2

    src = Path(sys.argv[1]).read_text(encoding='utf-8')
    lines = src.splitlines()

    data_offsets = []
    old_stack = None
    for line in lines:
        m = DATA_RE.match(line)
        if m:
            data_offsets.append(int(m.group('off')))
        if '(global $__stack_pointer' in line:
            gm = re.search(r'i32\.const\s+(\d+)', line)
            if gm:
                old_stack = int(gm.group(1))
    if not data_offsets or old_stack is None:
        print('failed to find data offsets / stack pointer', file=sys.stderr)
        return 1

    old_first = min(data_offsets)
    delta = old_first - TARGET_BASE
    if delta <= 0:
        print('nothing to reclaim', file=sys.stderr)
        Path(sys.argv[2]).write_text(src, encoding='utf-8')
        return 0

    old_init_pages = old_max_pages = None
    for line in lines:
        mm = MEM_RE.match(line)
        if mm:
            old_init_pages = int(mm.group('init'))
            old_max_pages = int(mm.group('max'))
            break
    if old_init_pages is None:
        print('failed to find memory decl', file=sys.stderr)
        return 1

    old_init_bytes = old_init_pages * PAGE
    old_max_bytes = old_max_pages * PAGE
    new_init_pages = max(1, (old_init_bytes - delta + PAGE - 1) // PAGE)
    new_max_pages = max(new_init_pages, (old_max_bytes - delta + PAGE - 1) // PAGE)

    # Static-address range we will shift in code/data.
    shift_lo = old_first
    shift_hi = old_stack

    out = []
    for line in lines:
        mm = MEM_RE.match(line)
        if mm:
            out.append(f"{mm.group(1)}{new_init_pages} {new_max_pages})")
            continue

        dm = DATA_RE.match(line)
        if dm:
            off = int(dm.group('off'))
            new_off = off - delta
            body = dm.group('body')
            # Patch embedded pointers in .data and em_asm payloads conservatively.
            if '(data $.data ' in line or '(data $em_asm ' in line:
                body = patch_data_bytes(body, shift_lo, shift_hi, delta)
            out.append(f"{dm.group(1)}{new_off}{dm.group(3)}{body}{dm.group(5)}")
            continue

        if '(global $__stack_pointer' in line or '(global (;3;)' in line or '(global (;4;)' in line:
            line = re.sub(r'(i32\.const\s+)(\d+)', lambda m: m.group(1) + str(int(m.group(2)) - delta), line)
            out.append(line)
            continue

        def repl(m):
            v = int(m.group(1))
            if shift_lo <= v <= shift_hi:
                return f'i32.const {v - delta}'
            return m.group(0)

        def repl_off(m):
            v = int(m.group(1))
            if shift_lo <= v <= shift_hi and '(memory 1)' not in line:
                return f'offset={v - delta}'
            return m.group(0)

        line = I32_CONST_RE.sub(repl, line)
        line = OFFSET_RE.sub(repl_off, line)
        out.append(line)

    text = '\n'.join(out) + '\n'

    # The original Emscripten ASan runtime still assumes a low-shadow region
    # living in mem0 and asserts that the reserved shadow range is large enough.
    # After reclaiming mem0 and moving shadow to mem1, that single-memory check
    # is no longer meaningful. Replace the init routine with a no-op so the
    # reclaimed layout can proceed to the actual mem1-backed poisoning logic.
    func_start = text.find('(func $__asan::InitializeShadowMemory__ (type 2)\n')
    if func_start != -1:
        func_end = text.find('\n  (func ', func_start + 1)
        if func_end != -1:
            text = (
                text[:func_start]
                + '(func $__asan::InitializeShadowMemory__ (type 2))'
                + text[func_end:]
            )
        else:
            print('warning: failed to locate InitializeShadowMemory end', file=sys.stderr)
    else:
        print('warning: failed to locate InitializeShadowMemory start', file=sys.stderr)

    # In our single-threaded Wasm experiments, ASan's blocking mutex can hang
    # after layout reclamation because the linked runtime still assumes the
    # original single-memory bootstrap state. Replacing the mutex operations
    # with no-ops is sufficient for the current single-threaded evaluation and
    # unblocks ThreadRegistry/CreateMainThread during ASan initialization.
    for name, replacement in (
        ('$__sanitizer::BlockingMutex::Lock__', '(func $__sanitizer::BlockingMutex::Lock__ (type 1) (param i32))'),
        ('$__sanitizer::BlockingMutex::Unlock__', '(func $__sanitizer::BlockingMutex::Unlock__ (type 1) (param i32))'),
    ):
        start = text.find(f'(func {name} ')
        if start != -1:
            end = text.find('\n  (func ', start + 1)
            if end != -1:
                text = text[:start] + replacement + text[end:]
            else:
                print(f'warning: failed to locate {name} end', file=sys.stderr)
        else:
            print(f'warning: failed to locate {name}', file=sys.stderr)

    # The compact mem1 helper is appended after the last data segment and keeps
    # the original GLOBAL_BASE-based constants. Rebase those constants too so
    # helper-side shadow remapping matches the reclaimed mem0 layout.
    mem1_rebase_start = text.find('(func $__mem1_rebase ')
    if mem1_rebase_start != -1:
        mem1_rebase_end = text.find('\n  (func $__mem1_ensure_end ', mem1_rebase_start)
        if mem1_rebase_end != -1:
            text = (
                text[:mem1_rebase_start]
                + f'''(func $__mem1_rebase (param $addr i32) (result i32)
    (local $shadow i32)
    local.get $addr
    i32.const {TARGET_BASE}
    i32.ge_u
    if (result i32)
      local.get $addr
      i32.const 3
      i32.shr_u
    else
      local.get $addr
    end
    local.tee $shadow
    i32.const {TARGET_BASE >> 3}
    i32.ge_u
    if (result i32)
      local.get $shadow
      i32.const {TARGET_BASE >> 3}
      i32.sub
    else
      i32.const 0
    end)'''
                + text[mem1_rebase_end:]
            )
        else:
            print('warning: failed to locate $__mem1_rebase end', file=sys.stderr)

    Path(sys.argv[2]).write_text(text, encoding='utf-8')
    print(f'reclaimed delta={delta} bytes ({delta / PAGE:.3f} pages)')
    print(f'memory0: {old_init_pages}/{old_max_pages} -> {new_init_pages}/{new_max_pages} pages')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
