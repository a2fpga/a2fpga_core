#include <stdint.h>
#include <a2fpga/a2fpga.h>

#ifndef __SOC_H__
#define __SOC_H__


static inline void soc_irq(void(*irq_handler)(uint32_t,uint32_t*)) {
    *((uint32_t*)8) = (uint32_t)irq_handler;
}

extern uint32_t soc_maskirq(uint32_t mask);

extern uint32_t soc_waitirq();

extern uint32_t soc_timer(uint32_t ticks);

static inline void soc_sbreak() {
    asm volatile ("sbreak" : : : "memory");
}

void soc_wait(uint32_t ms);

typedef struct soc_firmware_jump_table_t {
	uint8_t (*wait_for_cmd)();
	uint8_t (*wait_for_char)();
} soc_firmware_jump_table_t;


#endif