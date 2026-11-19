/*
 * hid_map — HID usage -> menu-button mapping and report decoding shared by
 * the USB host (usbhost.cpp) and the BLE HID host (ble_hid.c).
 *
 * Output is always the menu's A2PAD_* button word (a2fpga_regs.h): the
 * ESP32 menu's OK is A and back is B (BTN_OK / BTN_BACK in menu.c),
 * SELECT = Apple II <-> MCU, Y = menu <-> console.
 *
 * Two levels:
 *   - the fixed usage tables (keyboard page 7, consumer page 0x0C) and the
 *     consumer-page layout parser the USB path has used since the BL616
 *     port (usbh_hidinput.c), kept API-compatible;
 *   - a general report-map model for HID-over-GATT devices, which carry
 *     several report IDs in one map (keyboard + consumer on remotes;
 *     buttons + hat + sticks on gamepads) and deliver notifications WITHOUT
 *     the report-ID byte (the Report Reference descriptor names it).
 */
#ifndef HID_MAP_H
#define HID_MAP_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- fixed usage tables ------------------------------------------------- */
uint16_t hid_map_kbd_usage(uint8_t usage);          /* page 0x07 */
uint16_t hid_map_consumer_usage(uint16_t usage);    /* page 0x0C */
/* Gamepad button number (page 0x09 usage, 1-based) -> A2PAD bit. nbuttons
 * is the pad's declared button count: >= 15 selects the Linux-gamepad
 * order used by the BLE pads that exist (Xbox fw 5.x, Stadia, Steam):
 * 1 A, 2 B, 4 X, 5 Y, 11 View/Select, 12 Menu/Start, 13 guide; smaller
 * pads get 1 A, 2 B, 3 X, 4 Y, 7 Select, 8 Start. */
uint16_t hid_map_pad_button(uint16_t button, uint8_t nbuttons);

/* ---- USB boot keyboard + consumer layout (usbhost.cpp) ------------------- */
/* Boot-protocol keyboard report [mods, reserved, key1..key6] -> buttons. */
uint16_t hid_decode_boot_kbd(const uint8_t *buf, int n);

/* consumer-page input report layout, from the report descriptor */
typedef struct {
    bool     valid;
    bool     is_array;     /* array of usage codes vs 1-bit-per-usage bitmap */
    uint8_t  rid;          /* report ID (0 = none) */
    uint8_t  field_bits;   /* array: bits per entry (8/16); bitmap: 1 */
    uint8_t  field_count;  /* array: entries; bitmap: bits */
    uint16_t usages[16];   /* bitmap only: usage per bit position */
    uint8_t  nusages;
} hid_consumer_layout_t;

/* Minimal parse: the first Input item on the Consumer page. Prefers a
 * usage-code ARRAY over a bitmap (usbh_hidinput.c behaviour). */
void     hid_parse_consumer_layout(const uint8_t *d, uint32_t len, hid_consumer_layout_t *out);
/* Decode a USB interrupt-IN report (report-ID byte included when rid != 0).
 * Returns the button word, or 0 when the report is not this layout's. */
uint16_t hid_decode_consumer(const hid_consumer_layout_t *c, const uint8_t *buf, int n);

/* ---- general report map (BLE HOGP) ---------------------------------------- */
typedef enum {
    HF_KBD_ARRAY,      /* page 7 key-code array                  */
    HF_CONSUMER_ARRAY, /* page 0x0C usage-code array             */
    HF_CONSUMER_BITS,  /* page 0x0C one bit per usage            */
    HF_BUTTONS,        /* page 9, one bit per button from usage_min */
    HF_HAT,            /* page 1 usage 0x39, 8-way hat           */
    HF_AXIS_X,         /* page 1 usage 0x30 (also 0x32 Z = right stick X: ignored) */
    HF_AXIS_Y,         /* page 1 usage 0x31                      */
} hid_field_kind_t;

typedef struct {
    uint8_t  rid;          /* report ID the field lives in (0 = none)      */
    uint8_t  kind;         /* hid_field_kind_t                             */
    uint16_t bit_off;      /* first bit, counted from the start of the report
                            * payload (report-ID byte NOT included)        */
    uint8_t  bit_size;     /* bits per element                             */
    uint8_t  count;        /* elements                                     */
    uint16_t usage_min;    /* HF_BUTTONS: number of the first button       */
    int32_t  lmin, lmax;   /* logical range (hat / axes)                   */
    uint16_t usages[16];   /* HF_CONSUMER_BITS: usage per bit              */
    uint8_t  nusages;
} hid_field_t;

#define HID_MAX_FIELDS 24
typedef struct {
    hid_field_t f[HID_MAX_FIELDS];
    uint8_t     nf;
    uint8_t     nbuttons;  /* largest button count seen (pad layout pick)  */
    bool        has_kbd, has_consumer, has_pad;
} hid_report_map_t;

/* Parse a full HID report descriptor into input fields the menu can use.
 * Returns true when at least one usable field was found. */
bool     hid_parse_report_map(const uint8_t *d, uint32_t len, hid_report_map_t *out);
/* Decode one input report payload (no report-ID byte) of report ID rid. */
uint16_t hid_decode_report(const hid_report_map_t *m, uint8_t rid, const uint8_t *buf, int n);

#ifdef __cplusplus
}
#endif
#endif
