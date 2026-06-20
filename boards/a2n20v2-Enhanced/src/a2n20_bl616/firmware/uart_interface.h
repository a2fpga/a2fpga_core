/*
 * UART1 interface — USB↔UART passthrough with ring buffers.
 */

#ifndef _UART_INTERFACE_H
#define _UART_INTERFACE_H

#include <stdint.h>
#include <stdbool.h>

void uart_init(void);
void uart_start(void);
void uart_config(uint32_t baudrate, uint8_t databits, uint8_t parity, uint8_t stopbits);
void uart_process(void);

/* USB endpoint callbacks for UART interface */
void uart_bulk_out_cb(uint8_t busid, uint8_t ep, uint32_t nbytes);
void uart_bulk_in_cb(uint8_t busid, uint8_t ep, uint32_t nbytes);

/* Access to USB OUT data for CLI break-in detection */
uint32_t uart_get_usb_out_data(uint8_t *buf, uint32_t max_len);

/* Pause/resume UART passthrough (used by CLI) */
void uart_pause(void);
void uart_resume(void);

#endif
