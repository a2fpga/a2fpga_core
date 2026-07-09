/*
 * usbh_hidinput — generic USB HID keyboard / consumer-control input for the
 * MCU menu system.
 *
 * Implements the usbh_hid_run()/usbh_hid_stop() hooks of the stock CherryUSB
 * HID host class driver (CONFIG_CHERRYUSB_HOST_HID, enabled in proj.conf) and
 * turns key presses into the menu's XINPUT_* button vocabulary. main.c ORs
 * usbh_hidinput_buttons() into every menu_input() tick, so keys ride the same
 * edge-detection / hold-repeat path as the gamepad.
 *
 * Deliberately NO VID/PID matching — any USB keyboard, media remote, or air
 * mouse works, which keeps hardware optionality open:
 *
 *   - Keyboard interfaces (bInterfaceProtocol = 1): forced to BOOT protocol,
 *     which every boot-subclass keyboard must support and which guarantees the
 *     fixed 8-byte report [mods, rsvd, key1..key6] regardless of what the
 *     report descriptor says. Arrows/Enter/Esc drive the menu.
 *
 *   - Other HID interfaces: the report descriptor is parsed (minimally) for a
 *     Consumer-page (0x0C) input report — that's where remotes put Home / Back
 *     / volume. Both common encodings are handled: a usage-code array (16- or
 *     8-bit fields, e.g. the XING WEI 2.4G remote sends report [0x02, lo, hi])
 *     and a 1-bit-per-usage bitmap (media keyboards). Mouse / system-control
 *     reports on the same interface are ignored by report ID.
 *
 * Input decoding happens in the URB completion callback (HCD/interrupt
 * context) — like xinput_in_cb it must NOT touch SPI; it only updates the
 * per-interface button word and re-arms the URB. The reference remote's
 * button-to-usage map is documented in docs/ (captured 2026-07-06):
 * arrows/OK/Menu-key arrive as keyboard usages, Home=0x223 Back=0x224
 * Vol=0xE9/0xEA as consumer usages, Power=system-control (ignored), and the
 * mouse-toggle button sends nothing (internal air-mouse mode switch).
 */
#include "usbh_core.h"
#include "usbh_hid.h"
#include "usbh_xinput.h"   /* XINPUT_* button bits = the menu vocabulary */
#include "usbh_hidinput.h"
#include "osd_console.h"

/* ---- consumer-page input report layout (from the report descriptor) ----- */
struct consumer_layout {
    bool     valid;
    bool     is_array;     /* array of usage codes vs 1-bit-per-usage bitmap */
    bool     has_rid;      /* interface reports carry a report-ID prefix */
    uint8_t  rid;          /* report ID of the consumer report */
    uint8_t  field_size;   /* bits per field: 8/16 (array), 1 (bitmap) */
    uint8_t  field_count;
    uint16_t usages[16];   /* bitmap only: usage per bit position */
    uint8_t  nusages;
};

struct hidinput_slot {
    struct usbh_hid *hid;             /* NULL = slot free */
    bool is_kbd;
    struct consumer_layout con;
    volatile uint16_t btn_kbd;        /* current keyboard-sourced buttons */
    volatile uint16_t btn_con;        /* current consumer-sourced buttons */
};

static struct hidinput_slot g_slots[CONFIG_USBHOST_MAX_HID_CLASS];

/* Interrupt-IN report buffers (DMA: nocache + aligned, one per slot). */
static USB_NOCACHE_RAM_SECTION USB_MEM_ALIGNX uint8_t g_hidin_buf[CONFIG_USBHOST_MAX_HID_CLASS][64];
/* Report-descriptor read buffer. Only used inside usbh_hid_run(), which the
 * core calls from the single enumeration thread, so one shared buffer is safe.
 * (The stock driver's own read is capped at 64 bytes — too short for composite
 * remotes, hence this re-read.) */
static USB_NOCACHE_RAM_SECTION USB_MEM_ALIGNX uint8_t g_rdesc_buf[256];

/* ---- usage -> menu button mapping ---------------------------------------
 * Same conventions as the telnet mirror (telnetd.c): XINPUT_B=OK, XINPUT_A=
 * back, XINPUT_X=view, XINPUT_BACK=Apple<->MCU toggle, LB/RB=big +/- steps. */

static uint16_t map_kbd_usage(uint8_t u)
{
    switch (u) {
    case 0x52: return XINPUT_DPAD_UP;     /* Up arrow */
    case 0x51: return XINPUT_DPAD_DOWN;   /* Down arrow */
    case 0x50: return XINPUT_DPAD_LEFT;   /* Left arrow */
    case 0x4F: return XINPUT_DPAD_RIGHT;  /* Right arrow */
    case 0x28:                            /* Enter (remote OK button) */
    case 0x58: return XINPUT_B;           /* Keypad Enter        -> OK */
    case 0x29:                            /* Esc */
    case 0x2A: return XINPUT_A;           /* Backspace           -> back */
    case 0x65:                            /* Application ("menu" key; the
                                           * remote's hamburger button) */
    case 0x2B: return XINPUT_BACK;        /* Tab      -> Apple II <-> MCU */
    case 0x1C: return XINPUT_X;           /* Y        -> menu <-> console */
    case 0x2F: return XINPUT_LB;          /* [        -> big - */
    case 0x30: return XINPUT_RB;          /* ]        -> big + */
    default:   return 0;
    }
}

static uint16_t map_consumer_usage(uint16_t u)
{
    switch (u) {
    case 0x223:                           /* AC Home (remote Home button) */
    case 0x040: return XINPUT_BACK;       /* Menu     -> Apple II <-> MCU */
    case 0x224: return XINPUT_A;          /* AC Back             -> back */
    case 0x041: return XINPUT_B;          /* Menu Pick           -> OK */
    case 0x042: return XINPUT_DPAD_UP;    /* Menu Up */
    case 0x043: return XINPUT_DPAD_DOWN;  /* Menu Down */
    case 0x044: return XINPUT_DPAD_LEFT;  /* Menu Left */
    case 0x045: return XINPUT_DPAD_RIGHT; /* Menu Right */
    case 0x0E9: return XINPUT_RB;         /* Volume Up   -> big + */
    case 0x0EA: return XINPUT_LB;         /* Volume Down -> big - */
    default:    return 0;
    }
}

/* ---- minimal HID report-descriptor parse ---------------------------------
 * Extracts just enough to decode consumer-page input reports: for each Input
 * main item under Usage Page 0x0C, the report ID, field size/count, and (for
 * bitmaps) the per-bit usage list. Prefers a usage-code ARRAY over a bitmap
 * if the descriptor has both. Everything else (mouse axes, vendor pages,
 * system control) is skipped — we only need to recognize and ignore those
 * report IDs at runtime. */
static void parse_consumer_layout(const uint8_t *d, uint32_t len, struct consumer_layout *out)
{
    uint16_t usage_page = 0, rcount = 0;
    uint8_t  rsize = 0, rid = 0;
    bool     any_rid = false;
    uint16_t usages[16];
    uint8_t  nus = 0;
    uint16_t usage_min = 0;
    bool     have_min = false;

    memset(out, 0, sizeof(*out));

    uint32_t i = 0;
    while (i < len) {
        uint8_t prefix = d[i++];
        if (prefix == 0xFE) {              /* long item: [len][tag][data...] */
            if (i >= len) break;
            i += 2u + d[i];
            continue;
        }
        uint8_t isz = prefix & 3;
        if (isz == 3) isz = 4;
        if (i + isz > len) break;
        uint32_t val = 0;
        for (uint8_t k = 0; k < isz; k++)
            val |= (uint32_t)d[i + k] << (8 * k);
        i += isz;

        uint8_t type = (prefix >> 2) & 3;  /* 0=main 1=global 2=local */
        uint8_t tag = prefix >> 4;

        if (type == 1) {                   /* global */
            switch (tag) {
            case 0: usage_page = (uint16_t)val; break;
            case 7: rsize = (uint8_t)val; break;
            case 8: rid = (uint8_t)val; any_rid = true; break;
            case 9: rcount = (uint16_t)val; break;
            }
        } else if (type == 2) {            /* local */
            switch (tag) {
            case 0:                        /* Usage (32-bit form: page<<16) */
                if (nus < 16)
                    usages[nus++] = (uint16_t)val;
                break;
            case 1: usage_min = (uint16_t)val; have_min = true; break;
            }
        } else {                           /* main */
            if (tag == 8 && usage_page == 0x0C) {   /* Input, Consumer page */
                bool variable = (val & 2) != 0;
                if (variable && rsize == 1 && nus == 0 && have_min) {
                    /* bitmap declared as a usage RANGE: bit i = usage_min+i */
                    for (uint16_t u = 0; u < 16 && u < rcount; u++)
                        usages[nus++] = usage_min + u;
                }
                if (!variable && (rsize == 8 || rsize == 16)) {
                    /* usage-code array — take it, it beats any bitmap */
                    out->valid = true;
                    out->is_array = true;
                    out->has_rid = any_rid;
                    out->rid = rid;
                    out->field_size = rsize;
                    out->field_count = (uint8_t)MIN(rcount, 8u);
                } else if (variable && rsize == 1 && nus > 0 && !out->valid) {
                    out->valid = true;
                    out->is_array = false;
                    out->has_rid = any_rid;
                    out->rid = rid;
                    out->field_size = 1;
                    out->field_count = (uint8_t)MIN(rcount, 16u);
                    out->nusages = nus;
                    memcpy(out->usages, usages, sizeof(usages));
                }
            }
            nus = 0;                       /* locals reset at every main item */
            have_min = false;
        }
    }
}

/* ---- report decoding (URB callback = interrupt context, no SPI!) -------- */

static uint16_t decode_kbd(const uint8_t *buf, int nbytes)
{
    /* boot report: [mods, reserved, key1..key6]; 0x01 in a key slot = rollover
     * error (report unusable, keep previous state — signalled by 0xFFFF) */
    uint16_t bits = 0;
    if (nbytes < 3)
        return 0;
    if (buf[2] == 0x01)
        return 0xFFFF;
    for (int k = 2; k < nbytes && k < 8; k++)
        bits |= map_kbd_usage(buf[k]);
    return bits;
}

static void decode_consumer(struct hidinput_slot *s, const uint8_t *buf, int nbytes)
{
    const struct consumer_layout *c = &s->con;
    int off = 0;

    if (c->has_rid) {
        if (nbytes < 1 || buf[0] != c->rid)
            return;                        /* other report (mouse etc.): keep state */
        off = 1;
    }

    uint16_t bits = 0;
    if (c->is_array) {
        int fbytes = c->field_size / 8;
        for (int f = 0; f < c->field_count; f++) {
            int p = off + f * fbytes;
            if (p + fbytes > nbytes)
                break;
            uint16_t u = buf[p];
            if (fbytes == 2)
                u |= (uint16_t)buf[p + 1] << 8;
            bits |= map_consumer_usage(u);
        }
    } else {
        for (int f = 0; f < c->field_count && f < c->nusages; f++) {
            int p = off + (f >> 3);
            if (p >= nbytes)
                break;
            if (buf[p] & (1u << (f & 7)))
                bits |= map_consumer_usage(c->usages[f]);
        }
    }
    s->btn_con = bits;                     /* absolute state; 0 = all released */
}

static void hidinput_in_cb(void *arg, int nbytes)
{
    struct hidinput_slot *s = (struct hidinput_slot *)arg;
    struct usbh_hid *hid = s->hid;

    if (hid == NULL)
        return;                            /* slot torn down mid-flight */

    if (nbytes >= 0) {
        if (nbytes > 0) {
            uint8_t *buf = g_hidin_buf[hid->minor];
            if (s->is_kbd) {
                uint16_t bits = decode_kbd(buf, nbytes);
                if (bits != 0xFFFF)        /* rollover error: keep state */
                    s->btn_kbd = bits;
            } else if (s->con.valid) {
                decode_consumer(s, buf, nbytes);
            }
        }
        usbh_submit_urb(&hid->intin_urb);  /* re-arm for the next report */
    } else {
        /* transfer error (usually device gone): release any held buttons and
         * stop; disconnect/re-plug re-arms via usbh_hid_run() */
        s->btn_kbd = 0;
        s->btn_con = 0;
    }
}

/* SET_PROTOCOL with the interface number in wIndex, per the HID spec. (The
 * stock usbh_hid_set_protocol() hardcodes wIndex=0, which targets the wrong
 * interface on composite devices like keyboard+consumer remotes.) */
static int hidinput_set_boot_protocol(struct usbh_hid *hid)
{
    struct usb_setup_packet *setup = hid->hport->setup;

    setup->bmRequestType = USB_REQUEST_DIR_OUT | USB_REQUEST_CLASS | USB_REQUEST_RECIPIENT_INTERFACE;
    setup->bRequest = HID_REQUEST_SET_PROTOCOL;
    setup->wValue = HID_PROTOCOL_BOOT;
    setup->wIndex = hid->intf;
    setup->wLength = 0;

    return usbh_control_transfer(hid->hport, setup, NULL);
}

/* Hooks below run in the USB enumeration thread (like usbh_msc_run), so
 * control transfers and osd_log are both fine here. */
void usbh_hid_run(struct usbh_hid *hid_class)
{
    struct hidinput_slot *s = NULL;

    for (int i = 0; i < CONFIG_USBHOST_MAX_HID_CLASS; i++) {
        if (g_slots[i].hid == NULL) {
            s = &g_slots[i];
            break;
        }
    }
    if (s == NULL || hid_class->intin == NULL)
        return;

    memset(s, 0, sizeof(*s));
    s->is_kbd = (hid_class->protocol == HID_PROTOCOL_KEYBOARD);

    if (s->is_kbd) {
        /* Boot protocol guarantees the 8-byte report layout on any keyboard.
         * A non-boot-subclass keyboard may STALL this; proceed anyway — the
         * default report-protocol layout almost always matches boot. */
        if (hidinput_set_boot_protocol(hid_class) < 0)
            USB_LOG_WRN("HID kbd: SET_PROTOCOL(boot) failed, assuming boot layout\r\n");
        osd_log("USB HOST: KEYBOARD CONNECTED");
    } else {
        /* Not a keyboard: look for a consumer-control report (remote/media
         * keys). The mouse interface of a combo remote lands here too — its
         * descriptor carries the consumer collection alongside the mouse one. */
        int ret = usbh_hid_get_report_descriptor(
            hid_class, g_rdesc_buf, MIN(hid_class->report_size, (uint16_t)sizeof(g_rdesc_buf)));
        /* usbh_control_transfer returns setup(8) + data bytes */
        if (ret > 8)
            parse_consumer_layout(g_rdesc_buf, (uint32_t)(ret - 8), &s->con);
        if (!s->con.valid)
            return;                        /* plain mouse etc.: nothing to feed the menu */
        osd_log("USB HOST: REMOTE/MEDIA KEYS CONNECTED");
    }

    s->hid = hid_class;

    uint16_t mps = hid_class->intin->wMaxPacketSize & 0x7FF;
    usbh_int_urb_fill(&hid_class->intin_urb, hid_class->hport, hid_class->intin,
                      g_hidin_buf[hid_class->minor],
                      MIN(mps, (uint16_t)sizeof(g_hidin_buf[0])),
                      0 /* async */, hidinput_in_cb, s);
    usbh_submit_urb(&hid_class->intin_urb);
}

void usbh_hid_stop(struct usbh_hid *hid_class)
{
    for (int i = 0; i < CONFIG_USBHOST_MAX_HID_CLASS; i++) {
        if (g_slots[i].hid == hid_class) {
            /* URBs are already killed by usbh_hid_disconnect before this hook */
            g_slots[i].hid = NULL;
            g_slots[i].btn_kbd = 0;
            g_slots[i].btn_con = 0;
        }
    }
}

uint16_t usbh_hidinput_buttons(void)
{
    uint16_t bits = 0;
    for (int i = 0; i < CONFIG_USBHOST_MAX_HID_CLASS; i++) {
        if (g_slots[i].hid) {
            bits |= g_slots[i].btn_kbd;
            bits |= g_slots[i].btn_con;
        }
    }
    return bits;
}
