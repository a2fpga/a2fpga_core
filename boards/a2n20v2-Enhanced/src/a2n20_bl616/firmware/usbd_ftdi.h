/*
 * FTDI FT2232-compatible USB vendor class interface.
 * Two interfaces: Interface 0 = JTAG (EP 0x81/0x02), Interface 1 = UART (EP 0x83/0x04).
 */

#ifndef _USBD_FTDI_H
#define _USBD_FTDI_H

#include "usbd_core.h"

/* Endpoint addresses — matches real FT2232D layout */
#define JTAG_IN_EP   0x81
#define JTAG_OUT_EP  0x02
#define CDC_IN_EP    0x83
#define CDC_OUT_EP   0x04

/* FTDI status header prepended to all IN transfers */
#define FTDI_MODEM_STATUS_0  0x01
#define FTDI_MODEM_STATUS_1  0x60

/* Register an FTDI vendor-class interface with CherryUSB */
void usbd_ftdi_add_interface(struct usbd_interface *intf);

/* Callbacks implemented by main.c */
void usbd_ftdi_set_line_coding(uint32_t baudrate, uint8_t databits, uint8_t parity, uint8_t stopbits);
void usbd_ftdi_set_dtr(bool dtr);
void usbd_ftdi_set_rts(bool rts);

/* Accessors for latency timer / SOF tick */
uint32_t usbd_ftdi_get_sof_tick(void);
uint32_t usbd_ftdi_get_latency_timer1(void);
uint32_t usbd_ftdi_get_latency_timer2(void);

#endif
