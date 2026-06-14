/*
 * A2N20 BL616 Firmware — FT2232-compatible USB JTAG+Serial Bridge
 *
 * Provides the same FT2232D behavior as Sipeed's stock firmware:
 *   Interface 0 (EP 0x81/0x02): JTAG via MPSSE on GPIO10/12/14/16 → FPGA pins 5-8
 *   Interface 1 (EP 0x83/0x04): UART passthrough on GPIO11/13 → FPGA pins 70/69
 *
 * CLI break-in: Ctrl-X Ctrl-C Enter on the UART USB interface.
 */

#include <string.h>
#include <stdio.h>
#include "board.h"
#include "bflb_mtimer.h"
#include "usbd_core.h"
#include "usbd_ftdi.h"
#include "jtag_process.h"
#include "uart_interface.h"
#include "cli.h"
#include "fpga_spi.h"
#include "fpga_sd.h"

/* USB descriptor — defined in usb_descriptor.c */
extern const uint8_t ftdi_descriptor[];

/* CherryUSB requires this as a non-static symbol */
void usbd_event_handler(uint8_t event)
{
    switch (event) {
    case USBD_EVENT_CONFIGURED:
        /* Arm endpoints and send initial FTDI status packets */
        jtag_start();
        uart_start();
        break;
    default:
        break;
    }
}

/* FTDI callbacks — wire vendor requests to our UART interface */
void usbd_ftdi_set_line_coding(uint32_t baudrate, uint8_t databits, uint8_t parity, uint8_t stopbits)
{
    uart_config(baudrate, databits, parity, stopbits);
}

void usbd_ftdi_set_dtr(bool dtr)
{
    /* No DTR pin on Tang Nano 20K BL616→FPGA connection */
    (void)dtr;
}

void usbd_ftdi_set_rts(bool rts)
{
    /* No RTS pin on Tang Nano 20K BL616→FPGA connection */
    (void)rts;
}

/* JTAG endpoint callbacks */
static struct usbd_endpoint jtag_out_ep = {
    .ep_addr = JTAG_OUT_EP,
    .ep_cb = jtag_bulk_out_cb,
};
static struct usbd_endpoint jtag_in_ep = {
    .ep_addr = JTAG_IN_EP,
    .ep_cb = jtag_bulk_in_cb,
};

/* UART endpoint callbacks — CLI break-in detection happens inside uart_bulk_out_cb */
static struct usbd_endpoint uart_out_ep = {
    .ep_addr = CDC_OUT_EP,
    .ep_cb = uart_bulk_out_cb,
};
static struct usbd_endpoint uart_in_ep = {
    .ep_addr = CDC_IN_EP,
    .ep_cb = uart_bulk_in_cb,
};

/* Interfaces */
static struct usbd_interface intf0;  /* JTAG */
static struct usbd_interface intf1;  /* UART */

static void usb_init(void)
{
    usbd_desc_register(ftdi_descriptor);

    /* Interface 0: JTAG */
    usbd_ftdi_add_interface(&intf0);
    usbd_add_interface(&intf0);
    usbd_add_endpoint(&jtag_out_ep);
    usbd_add_endpoint(&jtag_in_ep);

    /* Interface 1: UART */
    usbd_ftdi_add_interface(&intf1);
    usbd_add_interface(&intf1);
    usbd_add_endpoint(&uart_out_ep);
    usbd_add_endpoint(&uart_in_ep);

    usbd_initialize();
}

int main(void)
{
    board_init();

    jtag_gpio_init();
    jtag_init();
    uart_init();
    usb_init();
    fpga_spi_init();
    fpga_sd_init();

    printf("A2N20 BL616 FT2232 bridge started\r\n");

    fpga_service_init();

    while (1) {
        if (cli_is_active()) {
            cli_process();
        } else {
            uart_process();
        }
        jtag_process();
        jtag_idle();
    }
}
