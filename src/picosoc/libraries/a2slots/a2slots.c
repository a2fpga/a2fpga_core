#include <stddef.h>
#include "a2slots.h"

#define mmio8(x) (*(volatile uint8_t*)(x))
#define mmio32(x) (*(volatile uint32_t*)(x))

void slots_set_card(uint8_t slot, uint8_t card)
{
    mmio8(0x08000000 + (slot << 2)) = card;
}

uint8_t slots_get_card(uint8_t slot)
{
    return mmio8(0x08000000 + (slot << 2));
}
