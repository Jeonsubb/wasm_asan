| Mode | Baseline | compact mem1 | Match |
| --- | --- | --- | --- |
| heap_oob | heap-buffer-overflow | heap-buffer-overflow | YES |
| stack_oob | stack-buffer-overflow | stack-buffer-overflow | YES |
| global_oob | global-buffer-overflow | global-buffer-overflow | YES |
| use_after_free | heap-use-after-free | heap-use-after-free | YES |
| double_free | double-free | double-free | YES |
| invalid_free | bad-free | bad-free | YES |
| use_after_scope | stack-use-after-scope | stack-use-after-scope | YES |
| leak | memory-leak | memory-leak | YES |
| container_overflow | container-overflow | container-overflow | YES |
| alloc_dealloc_mismatch | passthrough | passthrough | YES |
| use_after_return | passthrough | passthrough | YES |
| exploit_global_shadow_unpoison | passthrough | global-buffer-overflow | NO |
