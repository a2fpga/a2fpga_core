/*
 * Host tests for the pure USB-Ethernet protocol helpers (usbeth_proto.c):
 * CDC configuration-descriptor walk (ECM and NCM, with and without a Union
 * descriptor), the ECM MAC string, NCM NTB parameters, NTB16 parse/build.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "usbeth_proto.h"

static int fails = 0;
#define CHECK(c) do { if (!(c)) { fails++; printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

/* A realistic ECM configuration (RTL8153 config 2 / CH397A style):
 * config, intf0 (02/06/00) + header/union/ethernet fn + int IN 0x83,
 * intf1 alt0 (0A, no eps), intf1 alt1 (0A, bulk IN 0x81 / OUT 0x02). */
static const uint8_t ecm_cfg[] = {
    9, 0x02, 0x00, 0x00, 2, 2, 0, 0xA0, 50,         /* config, wTotalLength patched below */
    9, 0x04, 0, 0, 1, 0x02, 0x06, 0x00, 0,          /* ctrl interface 0 */
    5, 0x24, 0x00, 0x10, 0x01,                      /* header fn */
    5, 0x24, 0x06, 0x00, 0x01,                      /* union: master 0, slave 1 */
    13, 0x24, 0x0F, 0x03, 0, 0, 0, 0, 0xEA, 0x05, 0, 0, 0,   /* ethernet fn: iMAC=3, maxseg 1514 */
    7, 0x05, 0x83, 0x03, 0x10, 0x00, 8,             /* int IN 0x83, mps 16 */
    9, 0x04, 1, 0, 0, 0x0A, 0x00, 0x00, 0,          /* data intf 1 alt 0 */
    9, 0x04, 1, 1, 2, 0x0A, 0x00, 0x00, 0,          /* data intf 1 alt 1 */
    7, 0x05, 0x81, 0x02, 0x40, 0x00, 0,             /* bulk IN 0x81 mps 64 */
    7, 0x05, 0x02, 0x02, 0x40, 0x00, 0,             /* bulk OUT 0x02 */
};

static void test_ecm_descriptor(void)
{
    cdc_eth_fn_t fn;
    CHECK(cdc_parse_eth_function(ecm_cfg, sizeof(ecm_cfg), 0, &fn));
    CHECK(!fn.ncm);
    CHECK(fn.ctrl_intf == 0 && fn.data_intf == 1);
    CHECK(fn.data_found && fn.data_alt == 1);
    CHECK(fn.ep_in == 0x81 && fn.mps_in == 64);
    CHECK(fn.ep_out == 0x02 && fn.mps_out == 64);
    CHECK(fn.ep_notify == 0x83 && fn.mps_notify == 16);
    CHECK(fn.imac == 3 && fn.max_seg == 1514);
    /* wrong control interface -> invalid */
    CHECK(!cdc_parse_eth_function(ecm_cfg, sizeof(ecm_cfg), 1, &fn));
    /* truncated descriptor must not crash and must not claim data endpoints */
    CHECK(cdc_parse_eth_function(ecm_cfg, 40, 0, &fn) && !fn.data_found);
}

/* NCM function at interfaces 2/3, no Union descriptor (data = ctrl + 1),
 * data alt 1 carries the bulk pair. Preceded by an unrelated HID interface
 * to prove the walker ignores other functions. */
static const uint8_t ncm_cfg[] = {
    9, 0x02, 0x00, 0x00, 3, 1, 0, 0x80, 250,
    9, 0x04, 0, 0, 1, 0x03, 0x01, 0x01, 0,          /* HID keyboard, intf 0 */
    7, 0x05, 0x84, 0x03, 0x08, 0x00, 10,
    9, 0x04, 2, 0, 1, 0x02, 0x0D, 0x00, 0,          /* NCM ctrl intf 2 */
    5, 0x24, 0x00, 0x10, 0x01,
    13, 0x24, 0x0F, 0x07, 0, 0, 0, 0, 0xEA, 0x05, 0, 0, 0,
    6, 0x24, 0x1A, 0x00, 0x01, 0x00,                /* NCM fn */
    7, 0x05, 0x85, 0x03, 0x10, 0x00, 8,
    9, 0x04, 3, 0, 0, 0x0A, 0x00, 0x01, 0,          /* data intf 3 alt 0 */
    9, 0x04, 3, 1, 2, 0x0A, 0x00, 0x01, 0,          /* data intf 3 alt 1 */
    7, 0x05, 0x03, 0x02, 0x40, 0x00, 0,             /* OUT first this time */
    7, 0x05, 0x82, 0x02, 0x40, 0x00, 0,
};

static void test_ncm_descriptor(void)
{
    cdc_eth_fn_t fn;
    CHECK(cdc_parse_eth_function(ncm_cfg, sizeof(ncm_cfg), 2, &fn));
    CHECK(fn.ncm);
    CHECK(fn.data_intf == 3 && fn.data_found && fn.data_alt == 1);
    CHECK(fn.ep_in == 0x82 && fn.ep_out == 0x03);
    CHECK(fn.ep_notify == 0x85);
    CHECK(fn.imac == 7);
    /* the HID interface is not a CDC Ethernet function */
    CHECK(!cdc_parse_eth_function(ncm_cfg, sizeof(ncm_cfg), 0, &fn));
}

static void test_mac_string(void)
{
    /* "00E04C680001" as a string descriptor */
    uint8_t sd[2 + 12 * 2] = { 26, 0x03 };
    const char *hex = "00e04C680001";
    for (int i = 0; i < 12; i++) { sd[2 + 2 * i] = (uint8_t)hex[i]; sd[3 + 2 * i] = 0; }
    uint8_t mac[6];
    CHECK(cdc_parse_mac_string(sd, sizeof(sd), mac));
    const uint8_t want[6] = { 0x00, 0xE0, 0x4C, 0x68, 0x00, 0x01 };
    CHECK(memcmp(mac, want, 6) == 0);
    /* short, wrong type, non-hex, all-zero */
    CHECK(!cdc_parse_mac_string(sd, 10, mac));
    sd[1] = 0x02; CHECK(!cdc_parse_mac_string(sd, sizeof(sd), mac)); sd[1] = 0x03;
    sd[4] = 'g'; CHECK(!cdc_parse_mac_string(sd, sizeof(sd), mac)); sd[4] = '0';
    for (int i = 0; i < 12; i++) sd[2 + 2 * i] = '0';
    CHECK(!cdc_parse_mac_string(sd, sizeof(sd), mac));
}

static void test_ntb_params(void)
{
    uint8_t pb[28] = { 28, 0, 0x03, 0x00, 0x00, 0x40, 0x00, 0x00,   /* NTB16+32, in max 16384 */
                       4, 0, 0, 0, 4, 0, 0, 0,                        /* in div 4 rem 0 align 4 */
                       0x00, 0x08, 0x00, 0x00,                        /* out max 2048 */
                       0, 0, 0, 0, 0, 0, 10, 0 };                     /* out div/rem/align 0 -> sanitised; 10 dgrams */
    ncm_ntb_params_t p;
    CHECK(ncm_parse_ntb_params(pb, sizeof(pb), &p));
    CHECK(p.formats == 3 && p.in_max == 16384 && p.out_max == 2048);
    CHECK(p.out_div == 4 && p.out_align == 4 && p.out_rem == 0);
    CHECK(p.out_max_dgrams == 10);
    CHECK(!ncm_parse_ntb_params(pb, 20, &p));
}

/* collect datagrams */
static uint8_t got_buf[4][64]; static uint16_t got_len[4]; static int got_n;
static void dgram_cb(void *ctx, const uint8_t *f, uint16_t len)
{
    (void)ctx;
    if (got_n < 4) { memcpy(got_buf[got_n], f, len > 64 ? 64 : len); got_len[got_n] = len; }
    got_n++;
}

static void test_ntb_roundtrip(void)
{
    ncm_ntb_params_t p = { .formats = 1, .in_max = 2048, .in_div = 4, .in_rem = 0, .in_align = 4,
                           .out_max = 2048, .out_div = 16, .out_rem = 2, .out_align = 8, .out_max_dgrams = 0 };
    uint8_t frame[60]; for (int i = 0; i < 60; i++) frame[i] = (uint8_t)(0xA0 + i);
    uint8_t ntb[256];
    size_t n = ncm_ntb16_build(ntb, sizeof(ntb), frame, 60, 0x1234, &p);
    CHECK(n > 60 && n <= sizeof(ntb));
    /* header fields */
    CHECK(ntb[0] == 'N' && ntb[1] == 'C' && ntb[2] == 'M' && ntb[3] == 'H');
    CHECK(ntb[6] == 0x34 && ntb[7] == 0x12);
    CHECK((size_t)(ntb[8] | (ntb[9] << 8)) == n);
    size_t ndp = ntb[10] | (ntb[11] << 8);
    CHECK(ndp % 8 == 0 && ndp >= 12);
    CHECK(ntb[ndp + 3] == '0');
    size_t didx = ntb[ndp + 8] | (ntb[ndp + 9] << 8);
    CHECK(didx % 16 == 2);                           /* divisor 16, remainder 2 */
    CHECK(didx + 60 == n);
    /* parse it back */
    got_n = 0;
    CHECK(ncm_ntb16_parse(ntb, n, dgram_cb, NULL) == 1);
    CHECK(got_n == 1 && got_len[0] == 60 && memcmp(got_buf[0], frame, 60) == 0);
    /* too small a buffer / over the device's out max */
    CHECK(ncm_ntb16_build(ntb, 64, frame, 60, 0, &p) == 0);
    p.out_max = 70; CHECK(ncm_ntb16_build(ntb, sizeof(ntb), frame, 60, 0, &p) == 0);
}

static void test_ntb_parse_robust(void)
{
    /* two datagrams in one NDP, block length 0 (= transfer length), then a
     * second NDP with CRC flavour, plus hostile indices */
    uint8_t ntb[200]; memset(ntb, 0, sizeof(ntb));
    memcpy(ntb, "NCMH", 4); ntb[4] = 12; ntb[8] = 0; ntb[9] = 0; ntb[10] = 12; ntb[11] = 0;
    /* NDP0 at 12: len 24, next 40, entries (64,16) (80,20) terminator */
    memcpy(ntb + 12, "NCM0", 4); ntb[16] = 24; ntb[18] = 40;
    ntb[20] = 64; ntb[22] = 16;  ntb[24] = 80; ntb[26] = 20;
    /* NDP1 at 40: CRC flavour, len 16, entry (100,24) -> 20 bytes delivered */
    memcpy(ntb + 40, "NCM1", 4); ntb[44] = 16; ntb[46] = 0; ntb[48] = 100; ntb[50] = 24;
    for (int i = 64; i < 124; i++) ntb[i] = (uint8_t)i;
    got_n = 0;
    CHECK(ncm_ntb16_parse(ntb, 124, dgram_cb, NULL) == 3);
    CHECK(got_len[0] == 16 && got_buf[0][0] == 64);
    CHECK(got_len[1] == 20 && got_buf[1][0] == 80);
    CHECK(got_len[2] == 20 && got_buf[2][0] == 100);
    /* datagram running past the block is skipped, not delivered */
    ntb[22] = 200; got_n = 0;
    CHECK(ncm_ntb16_parse(ntb, 124, dgram_cb, NULL) == 2);
    /* NDP chain pointing backwards must terminate */
    ntb[22] = 16; ntb[46] = 12; got_n = 0;
    CHECK(ncm_ntb16_parse(ntb, 124, dgram_cb, NULL) == 3);
    /* bad signature / short */
    ntb[0] = 'X'; CHECK(ncm_ntb16_parse(ntb, 124, dgram_cb, NULL) == 0); ntb[0] = 'N';
    CHECK(ncm_ntb16_parse(ntb, 8, dgram_cb, NULL) == 0);
}

int main(void)
{
    test_ecm_descriptor();
    test_ncm_descriptor();
    test_mac_string();
    test_ntb_params();
    test_ntb_roundtrip();
    test_ntb_parse_robust();
    if (fails) { printf("%d FAILED\n", fails); return 1; }
    printf("usbeth_proto: all tests passed\n");
    return 0;
}
