#include <stddef.h>
#include <a2fpga/a2fpga.h>
#include "soc.h"

asm (
    ".global soc_maskirq\n"
    "soc_maskirq:\n"
    ".word 0x0605650b\n" // picorv32_maskirq_insn(a0, a0)
    "ret\n"
);

asm (
    ".global soc_timer\n"
    "soc_timer:\n"
    ".word 0x0a05650b\n" // picorv32_timer_insn(a0, a0)
    "ret\n"
);

asm (
    ".global soc_waitirq\n"
    "soc_waitirq:\n"
    ".word 0x0800450B\n" // picorv32_waitirq_insn(a0)
    "ret\n"
);

void *_sbrk(ptrdiff_t incr)
{
	extern unsigned char _end[];	// Defined by linker
	static unsigned long heap_end;

	if (heap_end == 0)
		heap_end = (long)_end;

	heap_end += incr;
	return (void *)(heap_end - incr);
}

void soc_wait(uint32_t ms)
{
    uint32_t current_time = reg_a2fpga_system_time;
    while ((reg_a2fpga_system_time - current_time) < ms) ;
}