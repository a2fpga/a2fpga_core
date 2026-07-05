/*
 * fpga_jtag — bit-banged JTAG + SPI-over-JTAG (Gowin 0x16) to the GW2AR's
 * external W25Q64 config flash. See fpga_jtag.c for the protocol notes.
 */
#ifndef _FPGA_JTAG_H
#define _FPGA_JTAG_H

#include <stdbool.h>
#include <stdint.h>

void     fpga_jtag_init_pins(void);
void     fpga_jtag_reset(void);
void     fpga_jtag_ir(uint8_t code);
uint32_t fpga_jtag_idcode(void);        /* GW2A(R)-18 = 0x0000081B */
uint32_t fpga_jtag_status(void);        /* Gowin status reg (IR 0x41) */

/* Erase the fabric SRAM and enter flash-access mode (the config controller
 * must own the die before the W25Q64 is reachable). The running bitstream
 * — screen, Apple II — DIES here. Returns false if the fabric refuses. */
bool fpga_jtag_flash_enter(void);

/* Reconfigure from external flash (RELOAD): boots whatever is in the
 * W25Q64, ~600 ms. The only way back after fpga_jtag_flash_enter(). */
void fpga_jtag_reload(void);

/* One CS-framed SPI transaction to the W25Q64 (enters 0x16 mode itself). */
void fpga_jtag_spi_xfer(const uint8_t *tx, uint8_t *rx, uint32_t len);

/* Read n bytes of config flash from addr (SPI 0x03). */
void fpga_jtag_flash_read(uint32_t addr, uint8_t *dst, uint32_t n);

#endif
