#include <stdint.h>


#ifndef __A2MEM_H__
#define __A2MEM_H__

void screen_clear();
void screen_home();
void screen_putchar(uint8_t c);

uint32_t peek32(uint32_t addr);
uint8_t peek8(uint32_t addr);
void poke32(uint32_t addr, uint32_t val);
void poke8(uint32_t addr, uint8_t val);


#endif

