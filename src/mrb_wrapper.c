#include <mruby.h>
#include <mruby/irep.h>
#include "mrb_bytecode.c"

int
main(void)
{
  mrb_state *mrb = mrb_open();
  if (!mrb) { return 1; }
  mrb_load_irep(mrb, mrb_bytecode);
  mrb_close(mrb);
  return 0;
}
