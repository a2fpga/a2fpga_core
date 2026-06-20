/*
 * FPGA SPI — Hardware SPI0 master with manual GPIO CS# for BL616→FPGA
 * communication per BL616_SPI_PROTOCOL.md.
 *
 * Pin mapping:
 *   GPIO0 = CS#  (manual GPIO output)
 *   GPIO1 = SCLK (SPI0 CLK)
 *   GPIO2 = MISO (SPI0 MISO, FPGA→MCU)
 *   GPIO3 = MOSI (SPI0 MOSI, MCU→FPGA)
 */

#ifndef _FPGA_SPI_H
#define _FPGA_SPI_H

#include <stdbool.h>
#include <stdint.h>

/* XFER memory spaces */
#define FPGA_SPACE_LOCAL  0  /* 256B local RAM */
#define FPGA_SPACE_SDRAM  1  /* SDRAM (byte addressed) */
#define FPGA_SPACE_FIFO   2  /* Bus event FIFO */
#define FPGA_SPACE_W5100  3  /* Uthernet2 (W5100) backing store, W5100 addresses */

/* Uthernet2 command-pending doorbell register (bits[3:0] = sockets 0-3).
 * Read to see which sockets have a pending Sn_CR; write 1s to clear. */
#define FPGA_REG_U2_CMD_PENDING  0x7A

/* Uthernet2 DEBUG: port-B (SPACE 3) write instrumentation (read-only). Shows
 * whether the MCU's SPACE 3 writes reach the card and with what address/data. */
#define FPGA_REG_U2_DBG_WRCNT    0x7B  /* port-B write count, low byte */
#define FPGA_REG_U2_DBG_ADDR_LO  0x7C  /* last port-B write address, low */
#define FPGA_REG_U2_DBG_ADDR_HI  0x7D  /* last port-B write address, high */
#define FPGA_REG_U2_DBG_WDATA    0x7E  /* last port-B write data */

/* STATUS register (0x06) bit fields */
#define FPGA_STATUS_RD_PENDING     (1 << 0)
#define FPGA_STATUS_WR_PENDING     (1 << 1)
#define FPGA_STATUS_A2BUS_RESET_N  (1 << 5)
#define FPGA_STATUS_SDRAM_READY    (1 << 6)
#define FPGA_STATUS_FPGA_CONFIGURED (1 << 7)

/* Initialize SPI0 hardware and GPIO0 as manual CS# */
void fpga_spi_init(void);

/* Register read (reg 0x00-0x7E). Returns data byte. */
uint8_t fpga_spi_reg_read(uint8_t reg);

/* Register write (reg 0x00-0x7E). */
void fpga_spi_reg_write(uint8_t reg, uint8_t val);

/* XFER write: send data to FPGA memory space */
void fpga_spi_xfer_write(uint8_t space, uint32_t addr, const uint8_t *data, uint16_t len);

/* XFER read: receive data from FPGA memory space */
void fpga_spi_xfer_read(uint8_t space, uint32_t addr, uint8_t *data, uint16_t len);

/* XFER fill: write repeating byte to FPGA memory space */
void fpga_spi_xfer_fill(uint8_t space, uint32_t addr, uint8_t val, uint16_t len);

/* Read STATUS register (0x06) */
uint8_t fpga_spi_read_status(void);

/* Poll STATUS until FPGA_CONFIGURED + SDRAM_READY, or timeout.
 * Returns true on success, false on timeout. */
bool fpga_spi_wait_ready(uint32_t timeout_ms);

/* Read DEVICE_ID registers (0x00-0x03) into 4-byte buffer */
void fpga_spi_read_device_id(uint8_t *buf);

/* Boot-time FPGA service init: wait for ready, hello message, configure */
void fpga_service_init(void);

#endif
