#include <stddef.h>
#include "a2fpga.h"

uint8_t wait_for_cmd()
{
	register uint8_t c;
	while ((c = reg_a2fpga_a2_cmd) == 0) ;
	reg_a2fpga_a2_cmd = 0;
	return c;
}

uint8_t wait_for_char()
{
	register uint8_t c;
	while ((c = reg_a2fpga_keycode) == 0) ;
	reg_a2fpga_keycode = 0;
	return c;
}

void wait_for_countdown(uint32_t us)
{
	reg_a2fpga_countdown = us;
	while (reg_a2fpga_countdown != 0) ;
}

uint8_t wait_for_a2reset()
{
	register uint8_t c;
	while ((c = reg_a2fpga_reset) == 0) ;
	reg_a2fpga_reset = 0;
	return c;
}
