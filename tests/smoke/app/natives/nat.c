#define HL_NAME(n) natives_##n
#include <hl.h>

HL_PRIM int HL_NAME(triple)(int x) { return x * 3; }
DEFINE_PRIM(_I32, triple, _I32)
