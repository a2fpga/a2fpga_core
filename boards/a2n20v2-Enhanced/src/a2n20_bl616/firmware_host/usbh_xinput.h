/*
 * usbh_xinput — CherryUSB host class driver for XInput (Xbox 360-style)
 * gamepads.
 *
 * XInput controllers are NOT HID. The gamepad interface is vendor-specific:
 *   bInterfaceClass    = 0xFF
 *   bInterfaceSubClass = 0x5D
 *   bInterfaceProtocol = 0x01
 * and delivers a 20-byte input report on an interrupt-IN endpoint. 8BitDo
 * controllers (SN30/SF30 Pro) in X-input mode enumerate as VID 0x045E /
 * PID 0x028E with exactly this interface, which is what this driver claims.
 */
#ifndef USBH_XINPUT_H
#define USBH_XINPUT_H

#include <stdbool.h>
#include <stdint.h>
#include "usbh_core.h"

struct usbh_xinput {
    struct usbh_hubport *hport;
    uint8_t intf;       /* interface number */
    uint8_t minor;
    struct usb_endpoint_descriptor *intin;  /* interrupt IN  (input reports) */
    struct usb_endpoint_descriptor *intout; /* interrupt OUT (rumble/LED, optional) */
    struct usbh_urb intin_urb;              /* armed by the app for async reads */
    struct usbh_urb intout_urb;             /* used by the init sequence */
};

/* Decoded controller state from a 20-byte XInput report. */
struct xinput_state {
    uint16_t buttons;        /* see XINPUT_* bit masks below */
    uint8_t  trig_left;      /* analog 0..255 */
    uint8_t  trig_right;     /* analog 0..255 */
    int16_t  thumb_lx;
    int16_t  thumb_ly;
    int16_t  thumb_rx;
    int16_t  thumb_ry;
};

/* XInput wButtons bit masks (report byte 2 = low, byte 3 = high). */
#define XINPUT_DPAD_UP    0x0001
#define XINPUT_DPAD_DOWN  0x0002
#define XINPUT_DPAD_LEFT  0x0004
#define XINPUT_DPAD_RIGHT 0x0008
#define XINPUT_START      0x0010
#define XINPUT_BACK       0x0020  /* labelled "Select" on the SN30 */
#define XINPUT_LTHUMB     0x0040
#define XINPUT_RTHUMB     0x0080
#define XINPUT_LB         0x0100
#define XINPUT_RB         0x0200
#define XINPUT_GUIDE      0x0400  /* Home / Star */
#define XINPUT_A          0x1000
#define XINPUT_B          0x2000
#define XINPUT_X          0x4000
#define XINPUT_Y          0x8000

/* Parse a raw report into st. Returns true if it was a valid input report
 * (type 0x00, length 0x14, at least 14 bytes). */
bool usbh_xinput_parse(const uint8_t *buf, int len, struct xinput_state *st);

/* Weak hooks called on connect/disconnect (override in the app). */
void usbh_xinput_run(struct usbh_xinput *xinput_class);
void usbh_xinput_stop(struct usbh_xinput *xinput_class);

#endif /* USBH_XINPUT_H */
