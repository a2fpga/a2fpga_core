/*
 * usbeth_proto.h -- pure (no ESP dependencies) helpers for the USB-Ethernet
 * uplink: CDC Ethernet descriptor parsing, the ECM MAC string, and NCM NTB16
 * framing. Everything here is unit-tested on the host (tests/host/).
 *
 * References: USB CDC 1.2 (Ethernet Networking Control Model, ECM) and
 * USB CDC NCM 1.0 (Network Control Model).
 */
#pragma once

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- descriptor constants -------------------------------------------- */
#define USB_DT_CONFIG           0x02
#define USB_DT_INTERFACE        0x04
#define USB_DT_ENDPOINT         0x05
#define USB_DT_CS_INTERFACE     0x24

#define USB_CLASS_CDC           0x02
#define USB_CLASS_CDC_DATA      0x0A
#define CDC_SUBCLASS_ECM        0x06
#define CDC_SUBCLASS_NCM        0x0D

#define CDC_FN_UNION            0x06   /* Union functional descriptor */
#define CDC_FN_ETHERNET         0x0F   /* Ethernet Networking functional descriptor */
#define CDC_FN_NCM              0x1A   /* NCM functional descriptor */

/* class-specific requests (bmRequestType 0x21 / 0xA1, wIndex = control interface) */
#define CDC_REQ_SET_ETHERNET_PACKET_FILTER  0x43
#define CDC_REQ_GET_NTB_PARAMETERS          0x80
#define CDC_REQ_SET_NTB_INPUT_SIZE          0x86
#define CDC_REQ_SET_NTB_FORMAT              0x8A

/* SET_ETHERNET_PACKET_FILTER bits */
#define CDC_PKT_PROMISCUOUS     0x0001
#define CDC_PKT_ALL_MULTICAST   0x0002
#define CDC_PKT_DIRECTED        0x0004
#define CDC_PKT_BROADCAST       0x0008
#define CDC_PKT_MULTICAST       0x0010

/* notifications on the control interface's interrupt endpoint */
#define CDC_NOTIFY_NETWORK_CONNECTION       0x00
#define CDC_NOTIFY_CONNECTION_SPEED_CHANGE  0x2A

/* ---- what the parser pulls out of a configuration descriptor ----------- */
typedef struct {
    bool     valid;          /* control interface found and it is ECM or NCM */
    bool     ncm;            /* NCM (true) or ECM (false) */
    uint8_t  ctrl_intf;      /* control interface number */
    uint8_t  data_intf;      /* data interface number (from the Union descriptor) */
    uint8_t  data_alt;       /* alternate setting of data_intf that carries the bulk pair */
    bool     data_found;     /* data_alt / ep_in / ep_out are valid */
    uint8_t  ep_in,  ep_out; /* bulk endpoints (address incl. direction bit) */
    uint16_t mps_in, mps_out;
    uint8_t  ep_notify;      /* interrupt IN on the control interface, 0 if none */
    uint16_t mps_notify;
    uint8_t  imac;           /* string index of the MAC address (ECM functional descriptor) */
    uint16_t max_seg;        /* wMaxSegmentSize (1514 normally) */
} cdc_eth_fn_t;

/* Walk a full configuration descriptor (cfg[0..len)) and describe the CDC
 * Ethernet function whose control interface is `ctrl_intf`. Returns
 * out->valid. Tolerates missing Union descriptors (data interface assumed
 * to be ctrl_intf + 1, as every real adapter does). */
bool cdc_parse_eth_function(const uint8_t *cfg, size_t len, uint8_t ctrl_intf, cdc_eth_fn_t *out);

/* Scan a whole configuration descriptor for its first CDC Ethernet (ECM or
 * NCM) function with a usable bulk pair. Used on configurations other than
 * the active one (dual-configuration adapters such as the Realtek RTL8152/
 * RTL8153, whose configuration 1 is vendor-specific and configuration 2 is
 * CDC-ECM). Returns false if the configuration has none. */
bool cdc_find_eth_function(const uint8_t *cfg, size_t len, cdc_eth_fn_t *out);

/* Build the smallest configuration descriptor that still describes the
 * function's data interface: configuration header, the data interface's
 * alternate setting with its bulk IN and bulk OUT endpoints, nothing else
 * (32 bytes). usbeth.c writes it over the host library's cached copy of the
 * active configuration (which it parses on every interface claim) so that a
 * claim of (data_intf, data_alt) allocates exactly two pipes -- the ESP32-S3
 * has eight host channels in all, one per pipe. Returns the length written
 * (CDC_MIN_CONFIG_LEN), 0 if cap is too small. */
#define CDC_MIN_CONFIG_LEN 32
size_t cdc_build_min_config(const cdc_eth_fn_t *fn, uint8_t cfg_value, uint8_t *out, size_t cap);

/* Decode an ECM iMACAddress string descriptor (bLength, 0x03, 12 UTF-16LE
 * hex digits) into 6 bytes. Returns false if malformed or all-zero. */
bool cdc_parse_mac_string(const uint8_t *desc, size_t len, uint8_t mac[6]);

/* ---- NCM NTB16 ---------------------------------------------------------- */
#define NCM_NTH16_SIG   0x484D434Eu   /* "NCMH" */
#define NCM_NDP16_SIG   0x304D434Eu   /* "NCM0" (no CRC) */
#define NCM_NDP16_CRC   0x314D434Eu   /* "NCM1" (datagrams carry a 4-byte CRC) */
#define NCM_NTH16_LEN   12
#define NCM_NDP16_HDR   8             /* signature, wLength, wNextNdpIndex */

/* GET_NTB_PARAMETERS reply (28 bytes, little endian) */
typedef struct {
    uint16_t formats;        /* bmNtbFormatsSupported: bit0 NTB16, bit1 NTB32 */
    uint32_t in_max;         /* dwNtbInMaxSize */
    uint16_t in_div, in_rem, in_align;
    uint32_t out_max;        /* dwNtbOutMaxSize */
    uint16_t out_div, out_rem, out_align;
    uint16_t out_max_dgrams; /* 0 = no limit */
} ncm_ntb_params_t;

/* Parse the 28-byte GET_NTB_PARAMETERS reply; false if too short. Divisor,
 * alignment and remainder are sanitised (divisor/alignment >= 4 and
 * remainder < divisor) so the builder can use them directly. */
bool ncm_parse_ntb_params(const uint8_t *buf, size_t len, ncm_ntb_params_t *out);

/* Datagram callback for ncm_ntb16_parse */
typedef void (*ncm_datagram_cb)(void *ctx, const uint8_t *frame, uint16_t len);

/* Walk one received NTB16 and hand every datagram to cb. Returns the number
 * of datagrams delivered (0 for a malformed block). All indices are bounds
 * checked against the transfer length; wBlockLength == 0 means "the whole
 * transfer". NDP16 with CRC ("NCM1") has the trailing 4 CRC bytes stripped. */
int ncm_ntb16_parse(const uint8_t *ntb, size_t len, ncm_datagram_cb cb, void *ctx);

/* Wrap one Ethernet frame into an NTB16 holding a single NDP16 with one
 * datagram, honouring the device's out-alignment rules from `p`. Returns
 * the NTB length written to out[0..cap), or 0 if it does not fit. */
size_t ncm_ntb16_build(uint8_t *out, size_t cap, const uint8_t *frame, uint16_t flen,
                       uint16_t seq, const ncm_ntb_params_t *p);

#ifdef __cplusplus
}
#endif
