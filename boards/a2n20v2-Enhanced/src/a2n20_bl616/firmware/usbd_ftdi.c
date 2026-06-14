/*
 * FTDI FT2232 vendor request handler for CherryUSB.
 * Handles SIO requests: baudrate, modem control, latency timers, EEPROM readback.
 */

#include "usbd_core.h"
#include "usbd_ftdi.h"
#include "jtag_process.h"

/* FTDI EEPROM emulation — returned for SIO_READ_EEPROM_REQUEST */
static const uint16_t ftdi_eeprom_info[] = {
    0x0800, 0x0403, 0x6010, 0x0500, 0x3280, 0x0000, 0x0200, 0x1096,
    0x1aa6, 0x0000, 0x0046, 0x0310, 0x004f, 0x0070, 0x0065, 0x006e,
    0x002d, 0x0045, 0x0043, 0x031a, 0x0055, 0x0053, 0x0042, 0x0020,
    0x0044, 0x0065, 0x0062, 0x0075, 0x0067, 0x0067, 0x0065, 0x0072,
    0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
    0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
    0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
    0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x1027
};

/* SIO request codes */
#define SIO_RESET_REQUEST             0x00
#define SIO_SET_MODEM_CTRL_REQUEST    0x01
#define SIO_SET_FLOW_CTRL_REQUEST     0x02
#define SIO_SET_BAUDRATE_REQUEST      0x03
#define SIO_SET_DATA_REQUEST          0x04
#define SIO_POLL_MODEM_STATUS_REQUEST 0x05
#define SIO_SET_EVENT_CHAR_REQUEST    0x06
#define SIO_SET_ERROR_CHAR_REQUEST    0x07
#define SIO_SET_LATENCY_TIMER_REQUEST 0x09
#define SIO_GET_LATENCY_TIMER_REQUEST 0x0A
#define SIO_SET_BITMODE_REQUEST       0x0B
#define SIO_READ_PINS_REQUEST         0x0C
#define SIO_READ_EEPROM_REQUEST       0x90
#define SIO_WRITE_EEPROM_REQUEST      0x91
#define SIO_ERASE_EEPROM_REQUEST      0x92

/* DTR/RTS bitmasks */
#define SIO_SET_DTR_MASK  0x1
#define SIO_SET_DTR_HIGH  (1 | (SIO_SET_DTR_MASK << 8))
#define SIO_SET_DTR_LOW   (0 | (SIO_SET_DTR_MASK << 8))
#define SIO_SET_RTS_MASK  0x2
#define SIO_SET_RTS_HIGH  (2 | (SIO_SET_RTS_MASK << 8))
#define SIO_SET_RTS_LOW   (0 | (SIO_SET_RTS_MASK << 8))

static volatile uint32_t sof_tick = 0;
static uint8_t latency_timer1 = 0x10;
static uint8_t latency_timer2 = 0x10;

static void ftdi_set_baudrate(uint32_t itdf_divisor, uint32_t *actual_baudrate)
{
#define FTDI_USB_CLK 48000000
    uint8_t frac[] = {0, 8, 4, 2, 6, 10, 12, 14};
    int divisor = itdf_divisor & 0x3fff;
    divisor <<= 4;
    divisor |= frac[(itdf_divisor >> 14) & 0x07];

    if (itdf_divisor == 0x01)
        *actual_baudrate = 2000000;
    else if (itdf_divisor == 0x00)
        *actual_baudrate = 3000000;
    else
        *actual_baudrate = FTDI_USB_CLK / divisor;
}

static int ftdi_vendor_request_handler(struct usb_setup_packet *setup, uint8_t **data, uint32_t *len)
{
    static uint32_t actual_baudrate = 1200;

    switch (setup->bRequest) {
    case SIO_READ_EEPROM_REQUEST:
        *data = (uint8_t *)&ftdi_eeprom_info[setup->wIndex];
        *len = 2;
        break;

    case SIO_RESET_REQUEST:
        /* wValue: 0=reset SIO, 1=purge RX, 2=purge TX */
        if (setup->wIndex <= 1)  /* Interface 0 (JTAG) */
            jtag_purge();
        break;

    case SIO_SET_MODEM_CTRL_REQUEST:
        if (setup->wValue == SIO_SET_DTR_HIGH)
            usbd_ftdi_set_dtr(true);
        else if (setup->wValue == SIO_SET_DTR_LOW)
            usbd_ftdi_set_dtr(false);
        else if (setup->wValue == SIO_SET_RTS_HIGH)
            usbd_ftdi_set_rts(true);
        else if (setup->wValue == SIO_SET_RTS_LOW)
            usbd_ftdi_set_rts(false);
        break;

    case SIO_SET_FLOW_CTRL_REQUEST:
        break;

    case SIO_SET_BAUDRATE_REQUEST: {
        uint8_t baudrate_high = (setup->wIndex >> 8);
        ftdi_set_baudrate(setup->wValue | (baudrate_high << 16), &actual_baudrate);
        if (actual_baudrate != 1200)
            usbd_ftdi_set_line_coding(actual_baudrate, 8, 0, 0);
        break;
    }

    case SIO_SET_DATA_REQUEST:
        if (actual_baudrate != 1200) {
            usbd_ftdi_set_line_coding(
                actual_baudrate,
                (uint8_t)setup->wValue,
                (uint8_t)(setup->wValue >> 8),
                (uint8_t)(setup->wValue >> 11));
        }
        break;

    case SIO_POLL_MODEM_STATUS_REQUEST:
        *data = (uint8_t *)&ftdi_eeprom_info[2];
        *len = 2;
        break;

    case SIO_SET_EVENT_CHAR_REQUEST:
    case SIO_SET_ERROR_CHAR_REQUEST:
        break;

    case SIO_SET_LATENCY_TIMER_REQUEST:
        if (setup->wIndex == 1)
            latency_timer1 = setup->wValue;
        else
            latency_timer2 = setup->wValue;
        break;

    case SIO_GET_LATENCY_TIMER_REQUEST:
        if (setup->wIndex == 1)
            *data = &latency_timer1;
        else
            *data = &latency_timer2;
        *len = 1;
        break;

    case SIO_SET_BITMODE_REQUEST:
    case SIO_READ_PINS_REQUEST:
        break;

    default:
        return -1;
    }
    return 0;
}

static void ftdi_notify_handler(uint8_t event, void *arg)
{
    (void)arg;
    switch (event) {
    case USBD_EVENT_RESET:
        latency_timer1 = 0x10;
        latency_timer2 = 0x10;
        sof_tick = 0;
        break;
    case USBD_EVENT_SOF:
        sof_tick++;
        break;
    default:
        break;
    }
}

/* Weak default implementations — overridden in main.c */
__attribute__((weak)) void usbd_ftdi_set_line_coding(uint32_t baudrate, uint8_t databits, uint8_t parity, uint8_t stopbits)
{
    (void)baudrate; (void)databits; (void)parity; (void)stopbits;
}

__attribute__((weak)) void usbd_ftdi_set_dtr(bool dtr) { (void)dtr; }
__attribute__((weak)) void usbd_ftdi_set_rts(bool rts) { (void)rts; }

uint32_t usbd_ftdi_get_sof_tick(void) { return sof_tick; }
uint32_t usbd_ftdi_get_latency_timer1(void) { return latency_timer1; }
uint32_t usbd_ftdi_get_latency_timer2(void) { return latency_timer2; }

void usbd_ftdi_add_interface(struct usbd_interface *intf)
{
    intf->class_interface_handler = NULL;
    intf->class_endpoint_handler = NULL;
    intf->vendor_handler = ftdi_vendor_request_handler;
    intf->notify_handler = ftdi_notify_handler;
}
