// fpga_jtag.h
// Bit-banged JTAG to the GW5AT-60 for standalone SPI-flash programming
// (FPGA self-update from the SD card, no PC attached).
#pragma once

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// GW5AT-60 JTAG IDCODE (openFPGALoader fpga_list)
#define FPGA_JTAG_IDCODE_GW5AT60 0x0001481Bu

void     fpga_jtag_init_pins(void);
void     fpga_jtag_release_pins(void);
void     fpga_jtag_reset(void);
uint32_t fpga_jtag_idcode(void);
uint32_t fpga_jtag_status(void);

// Kill the fabric (SRAM erase) and switch the GW5A into SPI-flash mode.
// The running bitstream dies here; fpga_jtag_reload() brings it back.
bool fpga_jtag_flash_enter(void);
bool fpga_jtag_flash_enter_keepsram(void);

// One SPI transaction to the external config flash while in SPI mode
// (mirrors openFPGALoader's spi_put_gw5a): cmd byte, then len full-duplex
// payload bytes. tx may be NULL (shifts the last bit level); rx may be NULL.
void fpga_jtag_spi_xfer(uint8_t cmd, const uint8_t *tx, uint8_t *rx,
                        uint32_t len);

// Read n bytes of the config flash at addr (SPI 0x03), SPI mode only.
void fpga_jtag_flash_read(uint32_t addr, uint8_t *dst, uint32_t n);

// Leave SPI mode and reconfigure the FPGA from the external flash.
void fpga_jtag_reload(void);

#ifdef __cplusplus
}
#endif
