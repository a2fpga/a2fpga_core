#include <stdint.h>


#ifndef __A2MEM_H__
#define __A2MEM_H__

// Memory-map of the A2FPGA SDRAM
// SDRAM mapped to 0x04xx_xxxx
// 0x0400_0000 - 0x0401_FFFF: 128KB Apple II shadow RAM (interleaved)
// 0x0402_0000 - 0x0403_FFFF: 128KB SOC RAM for OSD (interleaved)
// 0x0404_0000 - 0x0407_FFFF: 256KB DOC AUDIO RAM
// 0x0408_0000 - 0x040B_FFFF: 256KB Disk 1 RAM Buffer
// 0x040C_0000 - 0x040F_FFFF: 256KB Disk 2 RAM Buffer
// 0x0410_0000 - 0x043F_FFFF: 3MB unused (reserved for future expansion)
// 0x0440_0000 - 0x047F_FFFF: 4MB SOC RAM for firmware OS

void shadow_ram_init();

void screen_clear();
void screen_home();
void screen_putchar(uint8_t c);

uint32_t peek32(uint32_t addr);
uint8_t peek8(uint32_t addr);
void poke32(uint32_t addr, uint32_t val);
void poke8(uint32_t addr, uint8_t val);


#endif

