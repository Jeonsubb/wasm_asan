#include <cstdio>

extern "C" int get_dynamic_b();

int g_init_a = get_dynamic_b();

int main() {
  std::printf("init_order a=%d\n", g_init_a);
  return 0;
}
