#define HL_NAME(n) hlfw_##n
#include <hl.h>
#include "fw.h"

int fw_answer(void) { return FW_ANSWER; }

HL_PRIM int HL_NAME(fw_answer_hl)(void) { return fw_answer(); }
DEFINE_PRIM(_I32, fw_answer_hl, _NO_ARG)
