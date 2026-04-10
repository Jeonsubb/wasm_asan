#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

volatile uint64_t g_sink = 0;
uint8_t g_global_arr[16] = {0};

[[noreturn]] void usage(const char* prog) {
  std::fprintf(stderr,
               "Usage: %s <mode> [arg1] [arg2]\n"
               "  modes:\n"
               "    heap_oob\n"
               "    stack_oob\n"
               "    global_oob\n"
               "    use_after_free\n"
               "    double_free\n"
               "    invalid_free\n"
               "    alloc_dealloc_mismatch\n"
               "    use_after_scope\n"
               "    use_after_return\n"
               "    leak\n"
               "    container_overflow\n"
               "    exploit_global_shadow_unpoison\n"
                "    probe_global_poison\n"
               "    bench1 [iters=20] [size_mb=64]\n"
               "    bench2 [iters=50000] [block_bytes=4096]\n"
               "    bench3 [target_mb=512] [chunk_mb=32]\n",
               prog);
  std::exit(2);
}

int to_int_or_default(const char* s, int defv) {
  if (!s) return defv;
  char* end = nullptr;
  long v = std::strtol(s, &end, 10);
  if (!end || *end != '\0' || v <= 0) return defv;
  if (v > 1L << 30) return defv;
  return static_cast<int>(v);
}

#if defined(__has_feature)
#if __has_feature(address_sanitizer)
#define ASAN_PROBE_HAS_ASAN 1
#endif
#endif

#if defined(__SANITIZE_ADDRESS__)
#define ASAN_PROBE_HAS_ASAN 1
#endif

#if ASAN_PROBE_HAS_ASAN
extern "C" int __asan_address_is_poisoned(const void*);
#endif

__attribute__((no_sanitize("address"))) uint8_t* shadow_byte_for_addr(uintptr_t addr) {
  return reinterpret_cast<uint8_t*>(addr >> 3);
}

void mode_probe_global_poison() {
  const uintptr_t base = reinterpret_cast<uintptr_t>(g_global_arr);
  const uintptr_t end = base + sizeof(g_global_arr);
  int poison_base = 0;
  int poison_last = 0;
  int poison_end = 0;
  int poison_end1 = 0;
#if ASAN_PROBE_HAS_ASAN
  poison_base = __asan_address_is_poisoned(reinterpret_cast<const void*>(base));
  poison_last = __asan_address_is_poisoned(reinterpret_cast<const void*>(end - 1));
  poison_end = __asan_address_is_poisoned(reinterpret_cast<const void*>(end));
  poison_end1 = __asan_address_is_poisoned(reinterpret_cast<const void*>(end + 1));
#endif
  std::printf(
      "probe_global_poison base=%u end=%u poison_base=%d poison_last=%d poison_end=%d poison_end1=%d\n",
      static_cast<unsigned>(base),
      static_cast<unsigned>(end),
      poison_base,
      poison_last,
      poison_end,
      poison_end1);
}

void mode_heap_oob() {
  constexpr size_t n = 16;
  uint8_t* p = static_cast<uint8_t*>(std::malloc(n));
  if (!p) {
    std::perror("malloc");
    std::exit(1);
  }
  std::memset(p, 0x11, n);
  p[n] = 0xAA;  // intentional OOB write
  g_sink += p[0];
  std::printf("heap_oob done sink=%llu\n", static_cast<unsigned long long>(g_sink));
  std::free(p);
}

void mode_stack_oob() {
  uint8_t buf[16];
  std::memset(buf, 0x22, sizeof(buf));
  buf[sizeof(buf)] = 0xBB;  // intentional OOB write
  g_sink += buf[0];
  std::printf("stack_oob done sink=%llu\n", static_cast<unsigned long long>(g_sink));
}

void mode_global_oob() {
  g_global_arr[sizeof(g_global_arr)] = 0xCC;  // intentional OOB write
  g_sink += g_global_arr[0];
  std::printf("global_oob done sink=%llu\n", static_cast<unsigned long long>(g_sink));
}

__attribute__((no_sanitize("address"))) void unpoison_global_oob_shadow_byte() {
  const uintptr_t base = reinterpret_cast<uintptr_t>(g_global_arr);
  const uintptr_t target = base + sizeof(g_global_arr);
  uint8_t* shadow = shadow_byte_for_addr(target);
  const uint8_t before = *shadow;
  *shadow = 0;  // forcibly unpoison the global redzone shadow byte
  const uint8_t after = *shadow;
  std::printf("exploit_global_shadow_unpoison target=%u shadow=%u before=0x%02x after=0x%02x poisoned=%d\n",
              static_cast<unsigned>(target),
              static_cast<unsigned>(reinterpret_cast<uintptr_t>(shadow)),
              static_cast<unsigned>(before),
              static_cast<unsigned>(after),
              -1);
}

void mode_exploit_global_shadow_unpoison() {
  unpoison_global_oob_shadow_byte();
  mode_global_oob();  // perform the actual OOB in instrumented code
}

void mode_use_after_free() {
  constexpr size_t n = 32;
  uint8_t* p = static_cast<uint8_t*>(std::malloc(n));
  if (!p) {
    std::perror("malloc");
    std::exit(1);
  }
  std::memset(p, 0x5A, n);
  std::free(p);
  p[0] = 0xDD;  // intentional UAF write
  g_sink += p[0];
  std::printf("use_after_free done sink=%llu\n", static_cast<unsigned long long>(g_sink));
}

void mode_double_free() {
  constexpr size_t n = 32;
  uint8_t* p = static_cast<uint8_t*>(std::malloc(n));
  if (!p) {
    std::perror("malloc");
    std::exit(1);
  }
  std::memset(p, 0x6B, n);
  g_sink += p[0];
  std::free(p);
  std::free(p);  // intentional double-free
  std::printf("double_free done sink=%llu\n", static_cast<unsigned long long>(g_sink));
}

void mode_invalid_free() {
  constexpr size_t n = 64;
  uint8_t* p = static_cast<uint8_t*>(std::malloc(n));
  if (!p) {
    std::perror("malloc");
    std::exit(1);
  }
  std::memset(p, 0x7C, n);
  g_sink += p[1];
  std::free(p + 8);  // intentional invalid free
  std::printf("invalid_free done sink=%llu\n", static_cast<unsigned long long>(g_sink));
}

void mode_alloc_dealloc_mismatch() {
  int* p = new int[8];
  for (int i = 0; i < 8; ++i) p[i] = i;
  g_sink += static_cast<uint64_t>(p[0]);
  delete p;  // intentional mismatch: new[] vs delete
  std::printf("alloc_dealloc_mismatch done sink=%llu\n", static_cast<unsigned long long>(g_sink));
}

int* leak_stack_addr() {
  int local[4] = {1, 2, 3, 4};
  g_sink += static_cast<uint64_t>(local[0]);
  return &local[1];  // intentional escape
}

void mode_use_after_scope() {
  int* p = nullptr;
  {
    int local[8];
    for (int i = 0; i < 8; ++i) local[i] = i + 10;
    p = &local[3];
    g_sink += static_cast<uint64_t>(local[0]);
  }
  *p = 1234;  // use after scope if instrumentation supports it
  g_sink += static_cast<uint64_t>(*p);
  std::printf("use_after_scope done sink=%llu\n", static_cast<unsigned long long>(g_sink));
}

void mode_use_after_return() {
  int* p = leak_stack_addr();
  *p = 4321;  // use after return if supported
  g_sink += static_cast<uint64_t>(*p);
  std::printf("use_after_return done sink=%llu\n", static_cast<unsigned long long>(g_sink));
}

void mode_leak() {
  constexpr size_t n = 128;
  uint8_t* p = static_cast<uint8_t*>(std::malloc(n));
  if (!p) {
    std::perror("malloc");
    std::exit(1);
  }
  std::memset(p, 0xAB, n);
  g_sink += p[0];
  std::printf("leak allocated=%zu sink=%llu\n", n, static_cast<unsigned long long>(g_sink));
  // Intentionally leaked.
}

void mode_container_overflow() {
  std::vector<int> v;
  v.reserve(8);
  v.push_back(1);
  v[3] = 77;  // beyond size, within capacity; requires container annotations to detect
  g_sink += static_cast<uint64_t>(v[0]);
  std::printf("container_overflow done sink=%llu\n", static_cast<unsigned long long>(g_sink));
}

void mode_bench1(int iters, int size_mb) {
  const size_t n = static_cast<size_t>(size_mb) * 1024 * 1024;
  std::vector<uint8_t> buf(n, 1);
  auto t0 = std::chrono::steady_clock::now();

  uint64_t local = 0;
  for (int k = 0; k < iters; ++k) {
    for (size_t i = 0; i < n; i += 64) {
      buf[i] = static_cast<uint8_t>(buf[i] + static_cast<uint8_t>(k));
      local += buf[i];
    }
  }

  auto t1 = std::chrono::steady_clock::now();
  auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(t1 - t0).count();
  g_sink += local;
  std::printf("bench1 iters=%d size_mb=%d elapsed_ms=%lld sink=%llu\n",
              iters,
              size_mb,
              static_cast<long long>(ms),
              static_cast<unsigned long long>(g_sink));
}

void mode_bench2(int iters, int block_bytes) {
  auto t0 = std::chrono::steady_clock::now();
  uint64_t local = 0;

  for (int k = 0; k < iters; ++k) {
    uint8_t* p = static_cast<uint8_t*>(std::malloc(static_cast<size_t>(block_bytes)));
    if (!p) {
      std::fprintf(stderr, "malloc failed at iter=%d\n", k);
      std::exit(1);
    }
    std::memset(p, k & 0xff, static_cast<size_t>(block_bytes));
    local += p[0];
    local += p[block_bytes - 1];
    std::free(p);
  }

  auto t1 = std::chrono::steady_clock::now();
  auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(t1 - t0).count();
  g_sink += local;
  std::printf("bench2 iters=%d block_bytes=%d elapsed_ms=%lld sink=%llu\n",
              iters,
              block_bytes,
              static_cast<long long>(ms),
              static_cast<unsigned long long>(g_sink));
}

void mode_bench3(int target_mb, int chunk_mb) {
  const size_t chunk = static_cast<size_t>(chunk_mb) * 1024 * 1024;
  const int chunks = std::max(1, target_mb / std::max(1, chunk_mb));

  std::vector<uint8_t*> ptrs;
  ptrs.reserve(static_cast<size_t>(chunks));
  auto t0 = std::chrono::steady_clock::now();

  uint64_t local = 0;
  for (int c = 0; c < chunks; ++c) {
    uint8_t* p = static_cast<uint8_t*>(std::malloc(chunk));
    if (!p) {
      std::fprintf(stderr, "malloc failed at chunk=%d\n", c);
      break;
    }
    for (size_t i = 0; i < chunk; i += 4096) {
      p[i] = static_cast<uint8_t>(c + i);
      local += p[i];
    }
    ptrs.push_back(p);
  }

  auto t1 = std::chrono::steady_clock::now();
  auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(t1 - t0).count();
  g_sink += local;

  std::printf("bench3 target_mb=%d chunk_mb=%d allocated_chunks=%zu approx_alloc_mb=%zu elapsed_ms=%lld sink=%llu\n",
              target_mb,
              chunk_mb,
              ptrs.size(),
              (ptrs.size() * chunk) / (1024 * 1024),
              static_cast<long long>(ms),
              static_cast<unsigned long long>(g_sink));

  for (uint8_t* p : ptrs) {
    std::free(p);
  }
}

}  // namespace

extern "C" __attribute__((used)) uintptr_t asan_probe_global_addr() {
  return reinterpret_cast<uintptr_t>(g_global_arr);
}

int main(int argc, char** argv) {
  if (argc < 2) usage(argv[0]);

  const std::string mode = argv[1];
  if (mode == "heap_oob") {
    mode_heap_oob();
  } else if (mode == "stack_oob") {
    mode_stack_oob();
  } else if (mode == "global_oob") {
    mode_global_oob();
  } else if (mode == "exploit_global_shadow_unpoison") {
    mode_exploit_global_shadow_unpoison();
  } else if (mode == "use_after_free") {
    mode_use_after_free();
  } else if (mode == "double_free") {
    mode_double_free();
  } else if (mode == "invalid_free") {
    mode_invalid_free();
  } else if (mode == "alloc_dealloc_mismatch") {
    mode_alloc_dealloc_mismatch();
  } else if (mode == "use_after_scope") {
    mode_use_after_scope();
  } else if (mode == "use_after_return") {
    mode_use_after_return();
  } else if (mode == "leak") {
    mode_leak();
  } else if (mode == "container_overflow") {
    mode_container_overflow();
  } else if (mode == "probe_global_poison") {
    mode_probe_global_poison();
  } else if (mode == "bench1") {
    mode_bench1(to_int_or_default(argc > 2 ? argv[2] : nullptr, 20),
                to_int_or_default(argc > 3 ? argv[3] : nullptr, 64));
  } else if (mode == "bench2") {
    mode_bench2(to_int_or_default(argc > 2 ? argv[2] : nullptr, 50000),
                to_int_or_default(argc > 3 ? argv[3] : nullptr, 4096));
  } else if (mode == "bench3") {
    mode_bench3(to_int_or_default(argc > 2 ? argv[2] : nullptr, 512),
                to_int_or_default(argc > 3 ? argv[3] : nullptr, 32));
  } else {
    usage(argv[0]);
  }

  std::printf("done mode=%s sink=%llu\n", mode.c_str(), static_cast<unsigned long long>(g_sink));
  return 0;
}
