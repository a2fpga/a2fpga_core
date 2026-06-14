/*
 * FPGA Screen — OSD text output via SDRAM XFER writes.
 * Same text page and address encoding as PicoSOC a2mem.c.
 */

#ifndef _FPGA_SCREEN_H
#define _FPGA_SCREEN_H

#include <stdint.h>

/* Clear the 40-column text screen (fill with 0xA0 = space) */
void fpga_screen_clear(void);

/* Write a single character at the current cursor position */
void fpga_screen_putchar(uint8_t c);

/* Write a null-terminated string */
void fpga_screen_puts(const char *str);

/* Reset cursor to (0, 0) */
void fpga_screen_home(void);

#endif
