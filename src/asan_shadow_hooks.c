#include <stdint.h>

__attribute__((no_sanitize("address")))
uint8_t __asan_shadow_load8(uint32_t shadow_addr) {
  return *((volatile uint8_t*)(uintptr_t)shadow_addr);
}

__attribute__((no_sanitize("address")))
void __asan_shadow_store8(uint32_t shadow_addr, uint8_t v) {
  *((volatile uint8_t*)(uintptr_t)shadow_addr) = v;
}

__attribute__((no_sanitize("address")))
void __asan_shadow_store16(uint32_t shadow_addr, uint16_t v) {
  *((volatile uint16_t*)(uintptr_t)shadow_addr) = v;
}

__attribute__((no_sanitize("address")))
void __asan_shadow_store32(uint32_t shadow_addr, uint32_t v) {
  *((volatile uint32_t*)(uintptr_t)shadow_addr) = v;
}
