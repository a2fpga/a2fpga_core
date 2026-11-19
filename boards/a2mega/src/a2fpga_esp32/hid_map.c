/*
 * hid_map.c — see hid_map.h. Usage tables + consumer layout are the BL616
 * firmware_host/usbh_hidinput.c logic (moved here from usbhost.cpp when the
 * BLE host arrived, 2026-11-19); the general report-map parser is new.
 */
#include <string.h>

#include "a2fpga_regs.h"
#include "hid_map.h"

/* ---- fixed usage tables ---------------------------------------------------- */
uint16_t hid_map_kbd_usage(uint8_t u)
{
    switch (u) {
    case 0x52: return A2PAD_U;        /* Up arrow */
    case 0x51: return A2PAD_D;        /* Down arrow */
    case 0x50: return A2PAD_L;        /* Left arrow */
    case 0x4F: return A2PAD_R;        /* Right arrow */
    case 0x28:                        /* Enter (remote OK button) */
    case 0x58: return A2PAD_A;        /* Keypad Enter        -> OK */
    case 0x29:                        /* Esc */
    case 0x2A: return A2PAD_B;        /* Backspace           -> back */
    case 0x65:                        /* Application ("menu" key) */
    case 0x2B: return A2PAD_SELECT;   /* Tab      -> Apple II <-> MCU */
    case 0x1C: return A2PAD_Y;        /* Y        -> menu <-> console */
    default:   return 0;
    }
}

uint16_t hid_map_consumer_usage(uint16_t u)
{
    switch (u) {
    case 0x223:                       /* AC Home (remote Home button) */
    case 0x040: return A2PAD_SELECT;  /* Menu     -> Apple II <-> MCU */
    case 0x224: return A2PAD_B;       /* AC Back             -> back */
    case 0x041: return A2PAD_A;       /* Menu Pick           -> OK */
    case 0x042: return A2PAD_U;       /* Menu Up */
    case 0x043: return A2PAD_D;       /* Menu Down */
    case 0x044: return A2PAD_L;       /* Menu Left */
    case 0x045: return A2PAD_R;       /* Menu Right */
    default:    return 0;             /* volume keys: no menu meaning here */
    }
}

uint16_t hid_map_pad_button(uint16_t b, uint8_t nbuttons)
{
    if (nbuttons >= 15) {             /* Linux gamepad order (Xbox BLE, Stadia, Steam) */
        switch (b) {
        case 1:  return A2PAD_A;
        case 2:  return A2PAD_B;
        case 4:  return A2PAD_X;
        case 5:  return A2PAD_Y;
        case 11: return A2PAD_SELECT; /* View / Back               */
        case 12: return A2PAD_START;  /* Menu / Start              */
        case 13: return A2PAD_SELECT; /* guide: also Apple <-> MCU */
        default: return 0;
        }
    }
    switch (b) {                      /* small generic pads */
    case 1: return A2PAD_A;
    case 2: return A2PAD_B;
    case 3: return A2PAD_X;
    case 4: return A2PAD_Y;
    case 7: return A2PAD_SELECT;
    case 8: return A2PAD_START;
    default: return 0;
    }
}

/* ---- USB boot keyboard + consumer layout ------------------------------------ */
uint16_t hid_decode_boot_kbd(const uint8_t *buf, int n)
{
    uint16_t bits = 0;
    for (int k = 2; k < 8 && k < n; k++)
        if (buf[k] > 0x01) bits |= hid_map_kbd_usage(buf[k]);
    return bits;
}

void hid_parse_consumer_layout(const uint8_t *d, uint32_t len, hid_consumer_layout_t *out)
{
    uint16_t usage_page = 0, rcount = 0, rsize = 0, usage_min = 0;
    uint8_t  rid = 0;
    uint16_t usages[16]; uint8_t nus = 0; bool have_min = false;
    memset(out, 0, sizeof(*out));
    uint32_t i = 0;
    while (i < len) {
        uint8_t  b   = d[i++];
        uint8_t  sz  = b & 3; if (sz == 3) sz = 4;
        uint8_t  typ = (b >> 2) & 3, tag = b >> 4;
        uint32_t val = 0;
        for (uint8_t k = 0; k < sz && i < len; k++) val |= (uint32_t)d[i++] << (8 * k);
        if (typ == 1) {              /* global */
            switch (tag) {
            case 0: usage_page = (uint16_t)val; break;
            case 7: rsize = (uint16_t)val; break;
            case 9: rcount = (uint16_t)val; break;
            case 8: rid = (uint8_t)val; break;
            }
        } else if (typ == 2) {       /* local */
            switch (tag) {
            case 0: if (nus < 16) usages[nus++] = (uint16_t)val; break;
            case 1: usage_min = (uint16_t)val; have_min = true; break;
            case 2:                  /* usage max: bitmap declared as a range */
                if (have_min) { for (uint16_t u = 0; u < 16 && usage_min + u <= val; u++) if (nus < 16) usages[nus++] = usage_min + u; }
                break;
            }
        } else if (typ == 0) {       /* main */
            if (tag == 8 && usage_page == 0x0C && !out->valid) {   /* Input, Consumer page */
                bool is_array = (val & 0x02) == 0;                   /* bit1: 0 = array, 1 = variable */
                if (is_array && (rsize == 8 || rsize == 16)) {
                    out->valid = true; out->is_array = true; out->rid = rid;
                    out->field_bits = (uint8_t)rsize; out->field_count = (uint8_t)rcount;
                } else if (!is_array && rsize == 1 && nus > 0) {
                    out->valid = true; out->is_array = false; out->rid = rid;
                    out->field_bits = 1; out->field_count = (uint8_t)rcount;
                    out->nusages = nus; memcpy(out->usages, usages, sizeof(usages));
                }
            }
            nus = 0; have_min = false;   /* locals end at every main item (Collection included) */
        }
    }
}

uint16_t hid_decode_consumer(const hid_consumer_layout_t *c, const uint8_t *buf, int n)
{
    uint16_t bits = 0; int off = 0;
    if (!c->valid) return 0;
    if (c->rid) { if (n < 1 || buf[0] != c->rid) return 0; off = 1; }
    if (c->is_array) {
        int bytes = c->field_bits / 8;
        for (int f = 0; f < c->field_count && off + bytes <= n; f++, off += bytes) {
            uint16_t u = buf[off] | (bytes == 2 ? (uint16_t)buf[off + 1] << 8 : 0);
            if (u) bits |= hid_map_consumer_usage(u);
        }
    } else {
        for (int f = 0; f < c->field_count && f < c->nusages; f++) {
            int byte = off + f / 8, bit = f % 8;
            if (byte < n && (buf[byte] >> bit) & 1) bits |= hid_map_consumer_usage(c->usages[f]);
        }
    }
    return bits;
}

/* ---- general report map ------------------------------------------------------ */
/* bit cursor per report ID (Input items only) */
#define MAX_RIDS 8
typedef struct { uint8_t rid; uint16_t bits; } rid_cursor_t;

static rid_cursor_t *cursor_for(rid_cursor_t *c, int *nc, uint8_t rid)
{
    for (int i = 0; i < *nc; i++) if (c[i].rid == rid) return &c[i];
    if (*nc >= MAX_RIDS) return NULL;
    c[*nc].rid = rid; c[*nc].bits = 0;
    return &c[(*nc)++];
}

static hid_field_t *field_new(hid_report_map_t *m, uint8_t rid, uint8_t kind,
                              uint16_t bit_off, uint8_t size, uint8_t count)
{
    if (m->nf >= HID_MAX_FIELDS) return NULL;
    hid_field_t *f = &m->f[m->nf++];
    memset(f, 0, sizeof(*f));
    f->rid = rid; f->kind = kind; f->bit_off = bit_off; f->bit_size = size; f->count = count;
    return f;
}

bool hid_parse_report_map(const uint8_t *d, uint32_t len, hid_report_map_t *out)
{
    uint16_t usage_page = 0, rcount = 0, rsize = 0;
    int32_t  lmin = 0, lmax = 0;
    uint8_t  rid = 0;
    uint16_t usages[16]; uint8_t nus = 0;
    uint16_t usage_min = 0, usage_max = 0; bool have_min = false, have_max = false;
    rid_cursor_t cur[MAX_RIDS]; int ncur = 0;

    memset(out, 0, sizeof(*out));
    uint32_t i = 0;
    while (i < len) {
        uint8_t  b   = d[i++];
        uint8_t  sz  = b & 3; if (sz == 3) sz = 4;
        uint8_t  typ = (b >> 2) & 3, tag = b >> 4;
        uint32_t val = 0;
        for (uint8_t k = 0; k < sz && i < len; k++) val |= (uint32_t)d[i++] << (8 * k);
        /* sign-extend for logical min/max */
        int32_t sval = (int32_t)val;
        if (sz == 1) sval = (int8_t)val; else if (sz == 2) sval = (int16_t)val;

        if (typ == 1) {              /* global */
            switch (tag) {
            case 0: usage_page = (uint16_t)val; break;
            case 1: lmin = sval; break;
            case 2: lmax = sval; break;
            case 7: rsize = (uint16_t)val; break;
            case 8: rid = (uint8_t)val; break;
            case 9: rcount = (uint16_t)val; break;
            }
        } else if (typ == 2) {       /* local */
            switch (tag) {
            case 0: {                /* usage (page may ride in the upper 16 bits) */
                uint16_t u = (sz == 4) ? (uint16_t)(val & 0xFFFF) : (uint16_t)val;
                if (nus < 16) usages[nus++] = u;
                break;
            }
            case 1: usage_min = (uint16_t)val; have_min = true; break;
            case 2: usage_max = (uint16_t)val; have_max = true; break;
            }
        } else if (typ == 0) {       /* main */
            if (tag == 8) {          /* Input */
                rid_cursor_t *c = cursor_for(cur, &ncur, rid);
                uint16_t bit_off = c ? c->bits : 0;
                uint32_t total = (uint32_t)rsize * rcount;
                bool is_const = (val & 0x01) != 0;
                bool is_var   = (val & 0x02) != 0;
                bool is_rel   = (val & 0x04) != 0;   /* mouse deltas, not stick positions */
                if (!is_const && c && rsize && rcount) {
                    if (usage_page == 0x07 && !is_var && (rsize == 8 || rsize == 16)) {
                        if (field_new(out, rid, HF_KBD_ARRAY, bit_off, (uint8_t)rsize, (uint8_t)rcount))
                            out->has_kbd = true;
                    } else if (usage_page == 0x0C && !is_var && (rsize == 8 || rsize == 16)) {
                        if (field_new(out, rid, HF_CONSUMER_ARRAY, bit_off, (uint8_t)rsize, (uint8_t)rcount))
                            out->has_consumer = true;
                    } else if (usage_page == 0x0C && is_var && rsize == 1) {
                        hid_field_t *f = field_new(out, rid, HF_CONSUMER_BITS, bit_off, 1, (uint8_t)rcount);
                        if (f) {
                            out->has_consumer = true;
                            if (nus) { f->nusages = nus; memcpy(f->usages, usages, sizeof(usages)); }
                            else if (have_min) {
                                for (uint16_t u = 0; u < 16 && u < rcount; u++)
                                    f->usages[f->nusages++] = usage_min + u;
                            }
                        }
                    } else if (usage_page == 0x09 && is_var && rsize == 1) {
                        hid_field_t *f = field_new(out, rid, HF_BUTTONS, bit_off, 1, (uint8_t)rcount);
                        if (f) {
                            out->has_pad = true;
                            f->usage_min = have_min ? usage_min : (nus ? usages[0] : 1);
                            uint16_t nb = have_max && have_min ? (usage_max - usage_min + 1) : rcount;
                            if (nb > rcount) nb = rcount;
                            if (nb > out->nbuttons) out->nbuttons = (uint8_t)(nb > 255 ? 255 : nb);
                        }
                    } else if (usage_page == 0x01 && is_var && !is_rel) {
                        /* one field per element: X/Y/hat picked by usage order.
                         * Relative X/Y (air mouse, trackpad) carry no direction
                         * the menu could use and would fire L/R/U/D on a flick. */
                        for (uint16_t e = 0; e < rcount; e++) {
                            uint16_t u = nus ? usages[e < nus ? e : nus - 1]
                                             : (have_min ? (uint16_t)(usage_min + e) : 0);
                            uint8_t kind = 0xFF;
                            if (u == 0x39) kind = HF_HAT;
                            else if (u == 0x30) kind = HF_AXIS_X;
                            else if (u == 0x31) kind = HF_AXIS_Y;
                            if (kind != 0xFF) {
                                hid_field_t *f = field_new(out, rid, kind, (uint16_t)(bit_off + e * rsize), (uint8_t)rsize, 1);
                                if (f) { f->lmin = lmin; f->lmax = lmax; out->has_pad = true; }
                            }
                        }
                    }
                }
                if (c) c->bits = (uint16_t)(c->bits + total);
            }
            /* local items apply to the next main item only: clear on every
             * main item, Collection / End Collection included (a Usage
             * (Pointer) before Collection(Physical) would otherwise shift the
             * X/Y usage list by one) */
            nus = 0; have_min = have_max = false;
        }
    }
    return out->nf > 0;
}

static uint32_t get_bits(const uint8_t *buf, int n, uint32_t off, uint8_t size)
{
    uint32_t v = 0;
    for (uint8_t k = 0; k < size && k < 32; k++) {
        uint32_t bit = off + k;
        int byte = (int)(bit >> 3);
        if (byte >= n) break;
        if ((buf[byte] >> (bit & 7)) & 1) v |= 1u << k;
    }
    return v;
}

static uint16_t hat_bits(uint32_t v, int32_t lmin, int32_t lmax)
{
    int32_t d = (int32_t)v - lmin;
    if (lmax - lmin != 7 || d < 0 || d > 7) return 0;       /* null / unsupported */
    static const uint16_t dirs[8] = {
        A2PAD_U, A2PAD_U | A2PAD_R, A2PAD_R, A2PAD_D | A2PAD_R,
        A2PAD_D, A2PAD_D | A2PAD_L, A2PAD_L, A2PAD_U | A2PAD_L,
    };
    return dirs[d];
}

static int axis_dir(uint32_t raw, uint8_t size, int32_t lmin, int32_t lmax)
{
    int32_t v = (int32_t)raw;
    if (lmin < 0 && size < 32 && (raw & (1u << (size - 1))))      /* signed field */
        v = (int32_t)(raw | ~((1u << size) - 1));
    if (lmax <= lmin) return 0;
    int32_t span = lmax - lmin, mid = lmin + span / 2;
    if (v >= mid + span / 4) return 1;
    if (v <= mid - span / 4) return -1;
    return 0;
}

uint16_t hid_decode_report(const hid_report_map_t *m, uint8_t rid, const uint8_t *buf, int n)
{
    uint16_t bits = 0;
    for (uint8_t i = 0; i < m->nf; i++) {
        const hid_field_t *f = &m->f[i];
        if (f->rid != rid) continue;
        switch (f->kind) {
        case HF_KBD_ARRAY:
            for (uint8_t e = 0; e < f->count; e++) {
                uint32_t u = get_bits(buf, n, f->bit_off + e * f->bit_size, f->bit_size);
                if (u > 1 && u < 256) bits |= hid_map_kbd_usage((uint8_t)u);
            }
            break;
        case HF_CONSUMER_ARRAY:
            for (uint8_t e = 0; e < f->count; e++) {
                uint32_t u = get_bits(buf, n, f->bit_off + e * f->bit_size, f->bit_size);
                if (u) bits |= hid_map_consumer_usage((uint16_t)u);
            }
            break;
        case HF_CONSUMER_BITS:
            for (uint8_t e = 0; e < f->count && e < f->nusages; e++)
                if (get_bits(buf, n, f->bit_off + e, 1)) bits |= hid_map_consumer_usage(f->usages[e]);
            break;
        case HF_BUTTONS:
            for (uint8_t e = 0; e < f->count; e++)
                if (get_bits(buf, n, f->bit_off + e, 1))
                    bits |= hid_map_pad_button((uint16_t)(f->usage_min + e), m->nbuttons);
            break;
        case HF_HAT:
            bits |= hat_bits(get_bits(buf, n, f->bit_off, f->bit_size), f->lmin, f->lmax);
            break;
        case HF_AXIS_X: {
            int d = axis_dir(get_bits(buf, n, f->bit_off, f->bit_size), f->bit_size, f->lmin, f->lmax);
            if (d < 0) bits |= A2PAD_L; else if (d > 0) bits |= A2PAD_R;
            break;
        }
        case HF_AXIS_Y: {
            int d = axis_dir(get_bits(buf, n, f->bit_off, f->bit_size), f->bit_size, f->lmin, f->lmax);
            if (d < 0) bits |= A2PAD_U; else if (d > 0) bits |= A2PAD_D;    /* HID Y grows downward */
            break;
        }
        default: break;
        }
    }
    return bits;
}
