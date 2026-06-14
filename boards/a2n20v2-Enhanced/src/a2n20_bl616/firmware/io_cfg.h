/*
 * Tang Nano 20K BL616 pin definitions for A2N20 firmware.
 * Maps BL616 GPIOs to FPGA pins per v3921 schematic.
 */

#ifndef _IO_CFG_H
#define _IO_CFG_H

/* JTAG (BL616 → FPGA dedicated JTAG pins 5-8) */
#define TMS_PIN  GPIO_PIN_16  /* → FPGA pin 5 */
#define TCK_PIN  GPIO_PIN_10  /* → FPGA pin 6 */
#define TDI_PIN  GPIO_PIN_12  /* → FPGA pin 7 */
#define TDO_PIN  GPIO_PIN_14  /* → FPGA pin 8 */

/* UART1 (BL616 → FPGA) */
#define UART_TXD_PIN  GPIO_PIN_11  /* → FPGA pin 70 */
#define UART_RXD_PIN  GPIO_PIN_13  /* → FPGA pin 69 */

/* BL616 GPIO register addresses for direct bitbang access
 * GLB base: 0x20000000
 * GPIO_CFG128 (0xAC4) = input read (pins 0-31)
 * GPIO_CFG136 (0xAE4) = output value read/write (pins 0-31)
 * GPIO_CFG138 (0xAEC) = output SET (write 1 = set high)
 * GPIO_CFG140 (0xAF4) = output CLEAR (write 1 = set low) */
#define GPIO_IN_REG    (*(volatile uint32_t *)0x20000AC4)
#define GPIO_OUT_REG   (*(volatile uint32_t *)0x20000AE4)
#define GPIO_SET_REG   (*(volatile uint32_t *)0x20000AEC)
#define GPIO_CLR_REG   (*(volatile uint32_t *)0x20000AF4)

#endif
