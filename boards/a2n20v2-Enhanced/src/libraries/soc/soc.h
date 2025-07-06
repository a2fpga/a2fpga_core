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

typedef struct boot_params_t {
    uint32_t version;
    uint8_t enter_menu;
    char* FW_Date;
    char* FW_Time;
    void (*irq_handler)(uint32_t irq_mask, uint32_t *regs);
	uint8_t (*wait_for_cmd)();
	uint8_t (*wait_for_char)();
    uint8_t (*wait_for_a2reset)();
} boot_params_t;


#endif