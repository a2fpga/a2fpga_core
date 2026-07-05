/*
 * FPGA Screen — OSD text output via SDRAM XFER writes.
 * Same text page and address encoding as PicoSOC a2mem.c.
 */

#ifndef _FPGA_SCREEN_H
#define _FPGA_SCREEN_H

#include <stdbool.h>
#include <stdint.h>

#define FPGA_SCREEN_W 40
#define FPGA_SCREEN_H 24

/* Clear the 40-column text screen (fill with 0xA0 = space) */
void fpga_screen_clear(void);

/* Write a single character at the current cursor position */
void fpga_screen_putchar(uint8_t c);

/* Write a null-terminated string */
void fpga_screen_puts(const char *str);

/* Reset cursor to (0, 0) */
void fpga_screen_home(void);

/* Move the cursor (clamped to the screen) */
void fpga_screen_goto(int x, int y);

/* Inverse-video mode for subsequent putchar/puts (Apple II screen codes
 * $00-$3F). Lowercase is uppercased; only uppercase/digits/symbols render. */
void fpga_screen_set_inverse(bool inverse);

/* Shadow of the 40x24 text page (Apple II screen codes) maintained by the
 * writers above, for remote mirroring. gen bumps on every change. */
const uint8_t *fpga_screen_shadow_row(int y);
uint32_t       fpga_screen_shadow_gen(void);

#endif
