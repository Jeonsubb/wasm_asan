struct DynamicB {
  int x;
  DynamicB() : x(42) {}
};

DynamicB g_dynamic_b;

extern "C" int get_dynamic_b() {
  return g_dynamic_b.x;
}
