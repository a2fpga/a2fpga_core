/*
 * FPGA SD card — init the FPGA-side SD SPI tunnel registers.
 */

#include "fpga_sd.h"
#include "fpga_spi.h"

#define SD_REG_CTRL 0x6C

void fpga_sd_init(void)
{
    /* Set CS# high + slow clock (safe idle state) */
    fpga_spi_reg_write(SD_REG_CTRL, 0x03);
}
