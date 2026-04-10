(module
  (memory (export "mem") 2)

  ;; shadow base in the same memory
  (global $shadow_base i32 (i32.const 65536))

  (func $shadow_index (param $addr i32) (result i32)
    (i32.add (global.get $shadow_base)
             (i32.shr_u (local.get $addr) (i32.const 3))))

  ;; instrumented store: store to app memory and poison/unpoison shadow byte
  (func $instrumented_store (export "instrumented_store") (param $addr i32) (param $v i32)
    (i32.store8 (local.get $addr) (local.get $v))
    (i32.store8 (call $shadow_index (local.get $addr)) (i32.const 0)))

  ;; attacker can directly corrupt shadow because it is in same linear memory
  (func $corrupt_shadow_via_mem0 (export "corrupt_shadow_via_mem0") (param $addr i32) (param $tag i32)
    (i32.store8 (call $shadow_index (local.get $addr)) (local.get $tag)))

  (func $shadow_value (export "shadow_value") (param $addr i32) (result i32)
    (i32.load8_u (call $shadow_index (local.get $addr))))

  (func (export "demo") (result i32)
    (local $addr i32)
    (local $before i32)
    (local $after i32)
    (local.set $addr (i32.const 256))
    (call $instrumented_store (local.get $addr) (i32.const 65))
    (local.set $before (call $shadow_value (local.get $addr)))
    (call $corrupt_shadow_via_mem0 (local.get $addr) (i32.const 127))
    (local.set $after (call $shadow_value (local.get $addr)))
    (i32.or (i32.shl (local.get $before) (i32.const 8)) (local.get $after)))
)
