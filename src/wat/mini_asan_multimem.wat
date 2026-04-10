(module
  (memory (export "mem0") 2)
  (memory (export "mem1_shadow") 2)

  (func $shadow_index (param $addr i32) (result i32)
    (i32.shr_u (local.get $addr) (i32.const 3)))

  ;; instrumented store: app write in mem0, shadow update in mem1
  (func $instrumented_store (export "instrumented_store") (param $addr i32) (param $v i32)
    (i32.store8 (memory 0) (local.get $addr) (local.get $v))
    (i32.store8 (memory 1) (call $shadow_index (local.get $addr)) (i32.const 0)))

  ;; write to mem0 at an address that would be shadow in single-memory design
  (func $corrupt_mem0_shadow_like (export "corrupt_mem0_shadow_like") (param $addr i32) (param $tag i32)
    (local $fake_shadow_addr i32)
    (local.set $fake_shadow_addr
      (i32.add (i32.const 65536) (call $shadow_index (local.get $addr))))
    (i32.store8 (memory 0) (local.get $fake_shadow_addr) (local.get $tag)))

  (func $shadow_value (export "shadow_value") (param $addr i32) (result i32)
    (i32.load8_u (memory 1) (call $shadow_index (local.get $addr))))

  (func (export "demo") (result i32)
    (local $addr i32)
    (local $before i32)
    (local $after i32)
    (local.set $addr (i32.const 256))
    (call $instrumented_store (local.get $addr) (i32.const 65))
    (local.set $before (call $shadow_value (local.get $addr)))
    (call $corrupt_mem0_shadow_like (local.get $addr) (i32.const 127))
    (local.set $after (call $shadow_value (local.get $addr)))
    (i32.or (i32.shl (local.get $before) (i32.const 8)) (local.get $after)))
)
