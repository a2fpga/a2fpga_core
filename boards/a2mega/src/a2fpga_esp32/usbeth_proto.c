/*
 * usbeth_proto.c -- pure CDC ECM/NCM protocol helpers (see usbeth_proto.h).
 * No ESP-IDF, no FreeRTOS: compiled into the host unit tests as-is.
 */
#include "usbeth_proto.h"

#include <string.h>

static inline uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static inline uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static inline void wr16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static inline void wr32(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24); }

/* =========================================================================
 * Configuration descriptor walk
 * ========================================================================= */

bool cdc_parse_eth_function(const uint8_t *cfg, size_t len, uint8_t ctrl_intf, cdc_eth_fn_t *out)
{
    memset(out, 0, sizeof(*out));
    out->ctrl_intf = ctrl_intf;
    out->data_intf = (uint8_t)(ctrl_intf + 1);   /* default when no Union descriptor */
    out->max_seg   = 1514;

    bool have_union = false;
    int  cur_intf = -1, cur_alt = 0, cur_class = -1;
    /* per-alt-setting bulk pair of the data interface being walked */
    uint8_t  alt_in = 0, alt_out = 0; uint16_t alt_mps_in = 0, alt_mps_out = 0;

    size_t i = 0;
    while (i + 2 <= len) {
        uint8_t bl = cfg[i], bt = cfg[i + 1];
        if (bl < 2 || i + bl > len) break;
        const uint8_t *d = cfg + i;

        if (bt == USB_DT_INTERFACE && bl >= 9) {
            /* close the previous data-interface alt setting */
            if (cur_class == USB_CLASS_CDC_DATA && cur_intf == out->data_intf &&
                !out->data_found && alt_in && alt_out) {
                out->data_found = true; out->data_alt = (uint8_t)cur_alt;
                out->ep_in = alt_in; out->ep_out = alt_out;
                out->mps_in = alt_mps_in; out->mps_out = alt_mps_out;
            }
            cur_intf = d[2]; cur_alt = d[3]; cur_class = d[5];
            alt_in = alt_out = 0; alt_mps_in = alt_mps_out = 0;
            if (cur_intf == ctrl_intf && cur_alt == 0 && cur_class == USB_CLASS_CDC) {
                uint8_t sub = d[6];
                if (sub == CDC_SUBCLASS_ECM || sub == CDC_SUBCLASS_NCM) {
                    out->valid = true;
                    out->ncm = (sub == CDC_SUBCLASS_NCM);
                }
            }
        } else if (bt == USB_DT_CS_INTERFACE && cur_intf == ctrl_intf && bl >= 3) {
            switch (d[2]) {
            case CDC_FN_UNION:
                if (bl >= 5) { out->data_intf = d[4]; have_union = true; }
                break;
            case CDC_FN_ETHERNET:
                if (bl >= 13) { out->imac = d[3]; out->max_seg = rd16(d + 8); }
                break;
            default:
                break;
            }
        } else if (bt == USB_DT_ENDPOINT && bl >= 7) {
            uint8_t addr = d[2], attr = d[3] & 0x03; uint16_t mps = rd16(d + 4) & 0x07FF;
            if (cur_intf == ctrl_intf) {
                if (attr == 0x03 && (addr & 0x80) && !out->ep_notify) { out->ep_notify = addr; out->mps_notify = mps; }
            } else if (cur_class == USB_CLASS_CDC_DATA && attr == 0x02) {
                if (addr & 0x80) { alt_in = addr; alt_mps_in = mps; }
                else             { alt_out = addr; alt_mps_out = mps; }
            }
        }
        i += bl;
    }
    /* close the last alt setting of the walk */
    if (cur_class == USB_CLASS_CDC_DATA && cur_intf == out->data_intf &&
        !out->data_found && alt_in && alt_out) {
        out->data_found = true; out->data_alt = (uint8_t)cur_alt;
        out->ep_in = alt_in; out->ep_out = alt_out;
        out->mps_in = alt_mps_in; out->mps_out = alt_mps_out;
    }
    (void)have_union;   /* data_intf defaults to ctrl_intf + 1 when no Union descriptor */
    return out->valid;
}

/* =========================================================================
 * MAC string
 * ========================================================================= */

static int hexval(uint16_t c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

bool cdc_parse_mac_string(const uint8_t *desc, size_t len, uint8_t mac[6])
{
    if (len < 2 || desc[1] != 0x03) return false;
    size_t bl = desc[0];
    if (bl > len) bl = len;
    if (bl < 2 + 12 * 2) return false;
    uint8_t out[6]; int nz = 0;
    for (int i = 0; i < 6; i++) {
        int hi = hexval(rd16(desc + 2 + (2 * i) * 2));
        int lo = hexval(rd16(desc + 2 + (2 * i + 1) * 2));
        if (hi < 0 || lo < 0) return false;
        out[i] = (uint8_t)((hi << 4) | lo);
        nz |= out[i];
    }
    if (!nz) return false;
    memcpy(mac, out, 6);
    return true;
}

/* =========================================================================
 * NCM
 * ========================================================================= */

bool ncm_parse_ntb_params(const uint8_t *b, size_t len, ncm_ntb_params_t *out)
{
    memset(out, 0, sizeof(*out));
    if (len < 28 || rd16(b) < 28) return false;
    out->formats   = rd16(b + 2);
    out->in_max    = rd32(b + 4);
    out->in_div    = rd16(b + 8);
    out->in_rem    = rd16(b + 10);
    out->in_align  = rd16(b + 12);
    out->out_max   = rd32(b + 16);
    out->out_div   = rd16(b + 20);
    out->out_rem   = rd16(b + 22);
    out->out_align = rd16(b + 24);
    out->out_max_dgrams = rd16(b + 26);
    /* sanitise so the builder cannot divide by zero or misalign the NDP */
    if (out->out_div   < 4) out->out_div   = 4;
    if (out->out_align < 4) out->out_align = 4;
    if (out->in_div    < 4) out->in_div    = 4;
    if (out->in_align  < 4) out->in_align  = 4;
    if (out->out_rem >= out->out_div) out->out_rem = 0;
    if (out->in_rem  >= out->in_div)  out->in_rem  = 0;
    return true;
}

int ncm_ntb16_parse(const uint8_t *ntb, size_t len, ncm_datagram_cb cb, void *ctx)
{
    if (len < NCM_NTH16_LEN || rd32(ntb) != NCM_NTH16_SIG || rd16(ntb + 4) != NCM_NTH16_LEN)
        return 0;
    size_t block = rd16(ntb + 8);
    if (block == 0 || block > len) block = len;     /* 0 = ends with the transfer */
    size_t ndp = rd16(ntb + 10);
    int delivered = 0;
    for (int guard = 0; guard < 8 && ndp >= NCM_NTH16_LEN; guard++) {
        if (ndp + NCM_NDP16_HDR > block) break;
        uint32_t sig = rd32(ntb + ndp);
        bool crc;
        if (sig == NCM_NDP16_SIG) crc = false;
        else if (sig == NCM_NDP16_CRC) crc = true;
        else break;
        size_t nlen = rd16(ntb + ndp + 4);
        if (nlen < NCM_NDP16_HDR + 8 || ndp + nlen > block) break;
        size_t next = rd16(ntb + ndp + 6);
        for (size_t e = ndp + NCM_NDP16_HDR; e + 4 <= ndp + nlen; e += 4) {
            size_t didx = rd16(ntb + e), dlen = rd16(ntb + e + 2);
            if (didx == 0 || dlen == 0) break;              /* terminator */
            if (crc) { if (dlen <= 4) continue; dlen -= 4; }
            if (didx + dlen > block || dlen < 14) continue; /* skip bad entry, keep going */
            cb(ctx, ntb + didx, (uint16_t)dlen);
            delivered++;
        }
        if (next == 0 || next <= ndp) break;                /* no loops backwards */
        ndp = next;
    }
    return delivered;
}

static size_t align_up(size_t v, size_t a) { return (v + a - 1) / a * a; }

size_t ncm_ntb16_build(uint8_t *out, size_t cap, const uint8_t *frame, uint16_t flen,
                       uint16_t seq, const ncm_ntb_params_t *p)
{
    if (!flen) return 0;
    size_t ndp_off = align_up(NCM_NTH16_LEN, p->out_align);
    size_t ndp_len = NCM_NDP16_HDR + 2 * 4;                 /* one datagram + terminator */
    size_t d_off   = ndp_off + ndp_len;
    /* datagram index must satisfy index % divisor == remainder */
    d_off = align_up(d_off - p->out_rem, p->out_div) + p->out_rem;
    size_t total = d_off + flen;
    if (total > cap || total > 0xFFFF) return 0;
    if (p->out_max && total > p->out_max) return 0;

    memset(out, 0, d_off);
    wr32(out + 0, NCM_NTH16_SIG);
    wr16(out + 4, NCM_NTH16_LEN);
    wr16(out + 6, seq);
    wr16(out + 8, (uint16_t)total);
    wr16(out + 10, (uint16_t)ndp_off);

    wr32(out + ndp_off + 0, NCM_NDP16_SIG);
    wr16(out + ndp_off + 4, (uint16_t)ndp_len);
    wr16(out + ndp_off + 6, 0);                              /* no next NDP */
    wr16(out + ndp_off + 8, (uint16_t)d_off);
    wr16(out + ndp_off + 10, flen);
    /* terminator already zero */
    memcpy(out + d_off, frame, flen);
    return total;
}
