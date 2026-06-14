/*
 * FPGA SD card — init the FPGA-side SD SPI tunnel registers.
 */

#ifndef _FPGA_SD_H
#define _FPGA_SD_H

/* Initialize FPGA SD registers to safe defaults (CS# high, slow clock) */
void fpga_sd_init(void);

#endif
