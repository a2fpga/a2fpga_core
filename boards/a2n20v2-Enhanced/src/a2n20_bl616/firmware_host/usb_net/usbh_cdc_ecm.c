/*
 * usbh_cdc_ecm — in-tree CDC-ECM USB-Ethernet host driver. See usbh_cdc_ecm.h
 * for the design rationale (RTL8153 dual-config: match config-1 vendor iface by
 * VID/PID, then switch to the config-2 CDC-ECM and drive it manually).
 *
 * Derived from CherryUSB usbh_cdc_ecm.c (Apache-2.0, (c) 2022 sakumisu). The
 * config-switch, manual config-2 descriptor parse, SET_INTERFACE / string-desc
 * helpers (absent from the bundled v0.10.0 core), and the breadcrumb tracing
 * are the in-tree additions.
 */
#include "usbh_core.h"
#include "usb_osal.h"
#include "usbh_cdc_ecm.h"

#include <string.h>
#include <stdlib.h>
#include <errno.h>

/* This CherryUSB (v0.10.0) has no WAITING_FOREVER: a urb->timeout > 0 is a
 * synchronous transfer that blocks up to that many ms; timeout == 0 is async
 * (callback). The bulk endpoints here use synchronous transfers with a finite
 * timeout and loop — an idle RX timeout is benign (just re-arm). */
#define ECM_BULK_TIMEOUT_MS 1000

/* ---- breadcrumb tracing (HDMI DebugOverlay via FPGA scratch regs) --------
 * The host build is headless, so connect()-time progress is otherwise blind.
 * ecm_dbg_stage() is provided weakly here and overridden in main.c to write a
 * scratch reg; the default is a no-op so this file links standalone. */
__WEAK void ecm_dbg_stage(uint8_t code) { (void)code; }
__WEAK void ecm_dbg_byte(uint8_t idx, uint8_t val) { (void)idx; (void)val; }

/* Stage codes (visible on the overlay during bring-up). */
#define ECM_ST_CONNECT     0xE0
#define ECM_ST_SETCONFIG   0xE1
#define ECM_ST_GETCFGDESC  0xE2
#define ECM_ST_PARSED      0xE3
#define ECM_ST_EP_ACTIVE   0xE4
#define ECM_ST_SETINTF     0xE5
#define ECM_ST_FILTER      0xE6
#define ECM_ST_MAC         0xE7
#define ECM_ST_RUN         0xE8
#define ECM_ST_ERR         0xEF

/* general descriptor field offsets */
#define DESC_bLength            0
#define DESC_bDescriptorType    1
#define DESC_bDescriptorSubType 2

/* interface descriptor field offsets */
#define INTF_DESC_bInterfaceNumber  2
#define INTF_DESC_bAlternateSetting 3
#define INTF_DESC_bNumEndpoints     4
#define INTF_DESC_bInterfaceClass   5

/* endpoint descriptor field offsets */
#define EP_DESC_bEndpointAddress 2

#define CDC_ECM_PKT_FILTER 0x000C /* Directed | Broadcast */

USB_NOCACHE_RAM_SECTION USB_MEM_ALIGNX uint8_t g_ecm_rx_buffer[CDC_ECM_ETH_MAX_SEGSZE];
USB_NOCACHE_RAM_SECTION USB_MEM_ALIGNX uint8_t g_ecm_tx_buffer[CDC_ECM_ETH_MAX_SEGSZE];
USB_NOCACHE_RAM_SECTION USB_MEM_ALIGNX uint8_t g_ecm_ctrl_buffer[512];

static struct usbh_cdc_ecm g_cdc_ecm_class;
static bool g_cdc_ecm_inuse = false;

struct usbh_cdc_ecm *usbh_cdc_ecm_get_class(void)
{
    return g_cdc_ecm_inuse ? &g_cdc_ecm_class : NULL;
}

/* ---- low-level control helpers (bundled v0.10.0 lacks these wrappers) ---- */

static int ecm_set_configuration(struct usbh_cdc_ecm *ecm, uint8_t config)
{
    struct usb_setup_packet *setup = ecm->hport->setup;
    setup->bmRequestType = USB_REQUEST_DIR_OUT | USB_REQUEST_STANDARD | USB_REQUEST_RECIPIENT_DEVICE;
    setup->bRequest = USB_REQUEST_SET_CONFIGURATION;
    setup->wValue = config;
    setup->wIndex = 0;
    setup->wLength = 0;
    return usbh_control_transfer(ecm->hport->ep0, setup, NULL);
}

static int ecm_get_config_descriptor(struct usbh_cdc_ecm *ecm, uint8_t index, uint8_t *buf, uint16_t len)
{
    struct usb_setup_packet *setup = ecm->hport->setup;
    setup->bmRequestType = USB_REQUEST_DIR_IN | USB_REQUEST_STANDARD | USB_REQUEST_RECIPIENT_DEVICE;
    setup->bRequest = USB_REQUEST_GET_DESCRIPTOR;
    setup->wValue = (uint16_t)((USB_DESCRIPTOR_TYPE_CONFIGURATION << 8) | index);
    setup->wIndex = 0;
    setup->wLength = len;
    return usbh_control_transfer(ecm->hport->ep0, setup, buf);
}

static int ecm_set_interface(struct usbh_cdc_ecm *ecm, uint8_t intf, uint8_t alt)
{
    struct usb_setup_packet *setup = ecm->hport->setup;
    setup->bmRequestType = USB_REQUEST_DIR_OUT | USB_REQUEST_STANDARD | USB_REQUEST_RECIPIENT_INTERFACE;
    setup->bRequest = USB_REQUEST_SET_INTERFACE;
    setup->wValue = alt;
    setup->wIndex = intf;
    setup->wLength = 0;
    return usbh_control_transfer(ecm->hport->ep0, setup, NULL);
}

static int ecm_set_packet_filter(struct usbh_cdc_ecm *ecm, uint16_t filter)
{
    struct usb_setup_packet *setup = ecm->hport->setup;
    setup->bmRequestType = USB_REQUEST_DIR_OUT | USB_REQUEST_CLASS | USB_REQUEST_RECIPIENT_INTERFACE;
    setup->bRequest = CDC_REQUEST_SET_ETHERNET_PACKET_FILTER;
    setup->wValue = filter;
    setup->wIndex = ecm->ctrl_intf;
    setup->wLength = 0;
    return usbh_control_transfer(ecm->hport->ep0, setup, NULL);
}

/* Fetch string descriptor `index` (langid 0x0409) into buf (raw, incl header).
 * Returns the byte count, or <0 on error. */
static int ecm_get_string_descriptor(struct usbh_cdc_ecm *ecm, uint8_t index, uint8_t *buf, uint16_t len)
{
    struct usb_setup_packet *setup = ecm->hport->setup;
    setup->bmRequestType = USB_REQUEST_DIR_IN | USB_REQUEST_STANDARD | USB_REQUEST_RECIPIENT_DEVICE;
    setup->bRequest = USB_REQUEST_GET_DESCRIPTOR;
    setup->wValue = (uint16_t)((USB_DESCRIPTOR_TYPE_STRING << 8) | index);
    setup->wIndex = 0x0409;
    setup->wLength = len;
    int ret = usbh_control_transfer(ecm->hport->ep0, setup, buf);
    return ret;
}

/* The iMACAddress string is 12 UTF-16LE hex chars ("0011..."). Decode into the
 * 6-byte mac[]. Returns 0 on success. Falls back to a locally-administered MAC
 * (handled by the caller) if this fails. */
static int ecm_read_mac(struct usbh_cdc_ecm *ecm, uint8_t mac_str_idx)
{
    int ret = ecm_get_string_descriptor(ecm, mac_str_idx, g_ecm_ctrl_buffer, 64);
    if (ret < 0) {
        return ret;
    }
    /* g_ecm_ctrl_buffer[0]=bLength, [1]=0x03, then UTF-16LE chars. Pull the low
     * byte of each of the 12 units -> ASCII hex, then parse 6 bytes. */
    char ascii[13];
    for (int i = 0; i < 12; i++) {
        ascii[i] = (char)g_ecm_ctrl_buffer[2 + i * 2];
    }
    ascii[12] = '\0';
    for (int j = 0; j < 6; j++) {
        char pair[3] = { ascii[j * 2], ascii[j * 2 + 1], '\0' };
        ecm->mac[j] = (uint8_t)strtoul(pair, NULL, 16);
    }
    return 0;
}

/* ---- config-2 descriptor parse ------------------------------------------
 * Walk the raw config-2 descriptor blob (already in g_ecm_ctrl_buffer) and
 * locate the CDC-ECM control interface (+ its int-in EP and ECM functional
 * descriptor) and the CDC-data interface altsetting carrying the bulk pair. */
struct ecm_parse_result {
    uint8_t ctrl_intf;
    uint8_t data_intf;
    uint8_t data_alt;
    uint8_t mac_str_idx;
    uint16_t max_seg;
    struct usb_endpoint_descriptor intin_ep;
    struct usb_endpoint_descriptor bulkin_ep;
    struct usb_endpoint_descriptor bulkout_ep;
    bool have_ctrl, have_data, have_intin, have_bulkin, have_bulkout;
};

static int ecm_parse_config2(uint8_t *cfg, uint16_t total, struct ecm_parse_result *r)
{
    memset(r, 0, sizeof(*r));
    r->mac_str_idx = 0xff;

    uint8_t cur_intf = 0xff;
    uint8_t cur_class = 0xff;
    uint8_t cur_alt = 0;
    bool in_data_alt_with_eps = false;

    uint16_t off = 0;
    while (off + 2 <= total) {
        uint8_t blen = cfg[off + DESC_bLength];
        uint8_t btype = cfg[off + DESC_bDescriptorType];
        if (blen == 0) {
            break;
        }

        if (btype == USB_DESCRIPTOR_TYPE_INTERFACE) {
            cur_intf = cfg[off + INTF_DESC_bInterfaceNumber];
            cur_alt = cfg[off + INTF_DESC_bAlternateSetting];
            cur_class = cfg[off + INTF_DESC_bInterfaceClass];
            uint8_t neps = cfg[off + INTF_DESC_bNumEndpoints];

            if (cur_class == USB_DEVICE_CLASS_CDC && !r->have_ctrl) {
                /* Communications control interface (ECM subclass). */
                r->ctrl_intf = cur_intf;
                r->have_ctrl = true;
            } else if (cur_class == USB_DEVICE_CLASS_CDC_DATA) {
                r->data_intf = cur_intf;
                r->have_data = true;
                /* The altsetting that actually carries endpoints is the one we
                 * want (alt 0 of an ECM data iface usually has zero EPs). */
                in_data_alt_with_eps = (neps >= 2);
                if (in_data_alt_with_eps) {
                    r->data_alt = cur_alt;
                }
            } else {
                in_data_alt_with_eps = false;
            }
        } else if (btype == CDC_CS_INTERFACE) {
            if (cur_class == USB_DEVICE_CLASS_CDC &&
                cfg[off + DESC_bDescriptorSubType] == CDC_FUNC_DESC_ETHERNET_NETWORKING) {
                struct cdc_ecm_descriptor *d = (struct cdc_ecm_descriptor *)&cfg[off];
                r->mac_str_idx = d->iMACAddress;
                r->max_seg = d->wMaxSegmentSize;
            }
        } else if (btype == USB_DESCRIPTOR_TYPE_ENDPOINT) {
            struct usb_endpoint_descriptor *ep = (struct usb_endpoint_descriptor *)&cfg[off];
            uint8_t attr = cfg[off + 3]; /* bmAttributes */
            uint8_t addr = cfg[off + EP_DESC_bEndpointAddress];
            if ((attr & 0x03) == 0x03) { /* interrupt */
                if ((addr & 0x80) && cur_class == USB_DEVICE_CLASS_CDC) {
                    memcpy(&r->intin_ep, ep, sizeof(*ep));
                    r->have_intin = true;
                }
            } else if ((attr & 0x03) == 0x02) { /* bulk */
                if (in_data_alt_with_eps) {
                    if (addr & 0x80) {
                        memcpy(&r->bulkin_ep, ep, sizeof(*ep));
                        r->have_bulkin = true;
                    } else {
                        memcpy(&r->bulkout_ep, ep, sizeof(*ep));
                        r->have_bulkout = true;
                    }
                }
            }
        }

        off += blen;
    }

    if (!r->have_ctrl || !r->have_data || !r->have_bulkin || !r->have_bulkout) {
        return -1;
    }
    return 0;
}

/* ---- connect / disconnect ------------------------------------------------ */

static int usbh_cdc_ecm_connect(struct usbh_hubport *hport, uint8_t intf)
{
    struct usbh_cdc_ecm *ecm = &g_cdc_ecm_class;
    int ret;

    ecm_dbg_stage(ECM_ST_CONNECT);

    memset(ecm, 0, sizeof(*ecm));
    g_cdc_ecm_inuse = true;
    ecm->hport = hport;
    ecm->connect_status = CDC_ECM_NET_DISCONNECTED;
    hport->config.intf[intf].priv = ecm;

    /* 1. Switch the adapter from its (enumerated) config-1 vendor mode to the
     *    config-2 CDC-ECM. CherryUSB already set config 1 during enumeration. */
    ecm_dbg_stage(ECM_ST_SETCONFIG);
    ret = ecm_set_configuration(ecm, 2);
    if (ret < 0) {
        USB_LOG_ERR("ECM: SET_CONFIGURATION(2) failed %d\r\n", ret);
        ecm_dbg_stage(ECM_ST_ERR);
        return ret;
    }

    /* 2. Fetch config-2 descriptor: 9-byte header for wTotalLength, then full. */
    ecm_dbg_stage(ECM_ST_GETCFGDESC);
    ret = ecm_get_config_descriptor(ecm, 1, g_ecm_ctrl_buffer, 9);
    if (ret < 0) {
        USB_LOG_ERR("ECM: GET config2 hdr failed %d\r\n", ret);
        ecm_dbg_stage(ECM_ST_ERR);
        return ret;
    }
    uint16_t total = (uint16_t)g_ecm_ctrl_buffer[2] | ((uint16_t)g_ecm_ctrl_buffer[3] << 8);
    if (total > sizeof(g_ecm_ctrl_buffer)) {
        total = sizeof(g_ecm_ctrl_buffer);
    }
    ret = ecm_get_config_descriptor(ecm, 1, g_ecm_ctrl_buffer, total);
    if (ret < 0) {
        USB_LOG_ERR("ECM: GET config2 full failed %d\r\n", ret);
        ecm_dbg_stage(ECM_ST_ERR);
        return ret;
    }

    /* 3. Parse config-2 for the ECM control/data interfaces + endpoints. */
    struct ecm_parse_result pr;
    ret = ecm_parse_config2(g_ecm_ctrl_buffer, total, &pr);
    if (ret < 0) {
        USB_LOG_ERR("ECM: config2 parse incomplete (ctrl=%d data=%d in=%d out=%d)\r\n",
                    pr.have_ctrl, pr.have_data, pr.have_bulkin, pr.have_bulkout);
        ecm_dbg_stage(ECM_ST_ERR);
        return -1;
    }
    ecm->ctrl_intf = pr.ctrl_intf;
    ecm->data_intf = pr.data_intf;
    ecm->data_altsetting = pr.data_alt;
    ecm->max_segment_size = pr.max_seg ? pr.max_seg : CDC_ECM_ETH_MAX_SEGSZE;
    ecm_dbg_stage(ECM_ST_PARSED);
    ecm_dbg_byte(0, pr.ctrl_intf);
    ecm_dbg_byte(1, pr.data_intf);
    ecm_dbg_byte(2, pr.data_alt);

    /* 4. Activate endpoints (pipes built from the descriptors WE parsed, since
     *    hport->config still describes config 1). */
    if (pr.have_intin) {
        usbh_hport_activate_epx(&ecm->intin, hport, &pr.intin_ep);
    }
    usbh_hport_activate_epx(&ecm->bulkin, hport, &pr.bulkin_ep);
    usbh_hport_activate_epx(&ecm->bulkout, hport, &pr.bulkout_ep);
    ecm_dbg_stage(ECM_ST_EP_ACTIVE);

    /* 5. Select the data-interface altsetting that carries the bulk pair. */
    ret = ecm_set_interface(ecm, ecm->data_intf, ecm->data_altsetting);
    if (ret < 0) {
        USB_LOG_ERR("ECM: SET_INTERFACE(%d,%d) failed %d\r\n", ecm->data_intf, ecm->data_altsetting, ret);
        ecm_dbg_stage(ECM_ST_ERR);
        return ret;
    }
    ecm_dbg_stage(ECM_ST_SETINTF);

    /* 6. Packet filter: accept directed + broadcast (DHCP/ARP need broadcast). */
    ret = ecm_set_packet_filter(ecm, CDC_ECM_PKT_FILTER);
    if (ret < 0) {
        USB_LOG_ERR("ECM: SET_ETHERNET_PACKET_FILTER failed %d\r\n", ret);
        /* non-fatal: some adapters default to a usable filter */
    }
    ecm_dbg_stage(ECM_ST_FILTER);

    /* 7. MAC: read the adapter's iMACAddress string; fall back to a
     *    locally-administered address if unavailable. */
    if (pr.mac_str_idx != 0xff && ecm_read_mac(ecm, pr.mac_str_idx) == 0) {
        /* got real MAC */
    } else {
        ecm->mac[0] = 0x02; /* locally administered, unicast */
        ecm->mac[1] = 0xA2; ecm->mac[2] = 0xFA;
        ecm->mac[3] = 0x00; ecm->mac[4] = 0x00; ecm->mac[5] = 0x01;
    }
    USB_LOG_INFO("ECM MAC %02x:%02x:%02x:%02x:%02x:%02x  ctrl=%d data=%d alt=%d\r\n",
                 ecm->mac[0], ecm->mac[1], ecm->mac[2], ecm->mac[3], ecm->mac[4], ecm->mac[5],
                 ecm->ctrl_intf, ecm->data_intf, ecm->data_altsetting);
    ecm_dbg_stage(ECM_ST_MAC);
    for (int i = 0; i < 6; i++) ecm_dbg_byte(i, ecm->mac[i]);

    /* Assume link up after setup; the RTL8153 NETWORK_CONNECTION notification
     * is advisory and we don't want the data path to block on it for the MVP. */
    ecm->connect_status = CDC_ECM_NET_CONNECTED;

    snprintf(hport->config.intf[intf].devname, CONFIG_USBHOST_DEV_NAMELEN, "/dev/cdc_ether");
    USB_LOG_INFO("Register CDC ECM Class:%s\r\n", hport->config.intf[intf].devname);

    ecm_dbg_stage(ECM_ST_RUN);
    usbh_cdc_ecm_run(ecm);
    return 0;
}

static int usbh_cdc_ecm_disconnect(struct usbh_hubport *hport, uint8_t intf)
{
    struct usbh_cdc_ecm *ecm = (struct usbh_cdc_ecm *)hport->config.intf[intf].priv;
    if (ecm) {
        ecm->connect_status = CDC_ECM_NET_DISCONNECTED;
        if (ecm->bulkin)  usbh_pipe_free(ecm->bulkin);
        if (ecm->bulkout) usbh_pipe_free(ecm->bulkout);
        if (ecm->intin)   usbh_pipe_free(ecm->intin);

        if (hport->config.intf[intf].devname[0] != '\0') {
            USB_LOG_INFO("Unregister CDC ECM Class:%s\r\n", hport->config.intf[intf].devname);
            usbh_cdc_ecm_stop(ecm);
        }
        memset(ecm, 0, sizeof(*ecm));
        g_cdc_ecm_inuse = false;
    }
    return 0;
}

/* ---- data path (bulk IN rx thread + bulk OUT linkoutput) ----------------- */

static void usbh_cdc_ecm_rx_thread(void *argument)
{
    struct netif *netif = (struct netif *)argument;
    uint32_t rx_len;
    int ret;
    struct pbuf *p;
    uint16_t ep_mps;

find_class:
    while (usbh_find_class_instance("/dev/cdc_ether") == NULL) {
        usb_osal_msleep(500);
    }

    ep_mps = (g_cdc_ecm_class.hport->speed == USB_SPEED_FULL) ? 64 : 512;
    rx_len = 0;
    while (1) {
        if (usbh_cdc_ecm_get_class() == NULL) {
            goto find_class;
        }
        /* Cap each transfer so we never write past the buffer end. */
        uint32_t want = ep_mps;
        if (rx_len + want > CDC_ECM_ETH_MAX_SEGSZE) {
            want = CDC_ECM_ETH_MAX_SEGSZE - rx_len;
        }
        usbh_bulk_urb_fill(&g_cdc_ecm_class.bulkin_urb, g_cdc_ecm_class.bulkin,
                           &g_ecm_rx_buffer[rx_len], want, ECM_BULK_TIMEOUT_MS, NULL, NULL);
        ret = usbh_submit_urb(&g_cdc_ecm_class.bulkin_urb);
        if (ret == -ETIMEDOUT) {
            continue; /* idle: nothing arrived, keep any partial frame, re-arm */
        }
        if (ret == -ENODEV || ret == -ESHUTDOWN) {
            rx_len = 0;
            usb_osal_msleep(100);
            goto find_class;
        }
        if (ret < 0) {
            rx_len = 0;
            usb_osal_msleep(10);
            continue;
        }

        uint32_t got = g_cdc_ecm_class.bulkin_urb.actual_length;
        rx_len += got;

        /* A short packet (got < ep_mps, including a ZLP) ends the frame. */
        if (got < ep_mps || rx_len >= CDC_ECM_ETH_MAX_SEGSZE) {
            if (rx_len > 0) {
                p = pbuf_alloc(PBUF_RAW, rx_len, PBUF_POOL);
                if (p != NULL) {
                    memcpy(p->payload, g_ecm_rx_buffer, rx_len);
                    if (netif->input(p, netif) != ERR_OK) {
                        pbuf_free(p);
                    }
                }
            }
            rx_len = 0;
        }
    }
}

err_t usbh_cdc_ecm_linkoutput(struct netif *netif, struct pbuf *p)
{
    (void)netif;
    uint8_t *buf = g_ecm_tx_buffer;

    if (usbh_cdc_ecm_get_class() == NULL ||
        g_cdc_ecm_class.connect_status == CDC_ECM_NET_DISCONNECTED) {
        return ERR_IF;
    }
    if (p->tot_len > CDC_ECM_ETH_MAX_SEGSZE) {
        return ERR_BUF;
    }

    for (struct pbuf *q = p; q != NULL; q = q->next) {
        memcpy(buf, q->payload, q->len);
        buf += q->len;
    }

    usbh_bulk_urb_fill(&g_cdc_ecm_class.bulkout_urb, g_cdc_ecm_class.bulkout,
                       g_ecm_tx_buffer, p->tot_len, ECM_BULK_TIMEOUT_MS, NULL, NULL);
    if (usbh_submit_urb(&g_cdc_ecm_class.bulkout_urb) < 0) {
        return ERR_IF;
    }
    return ERR_OK;
}

void usbh_cdc_ecm_lwip_thread_init(struct netif *netif)
{
    usb_osal_thread_create("ecm_rx", 2048, CONFIG_USBHOST_PSC_PRIO + 1, usbh_cdc_ecm_rx_thread, netif);
}

__WEAK void usbh_cdc_ecm_run(struct usbh_cdc_ecm *cdc_ecm_class) { (void)cdc_ecm_class; }
__WEAK void usbh_cdc_ecm_stop(struct usbh_cdc_ecm *cdc_ecm_class) { (void)cdc_ecm_class; }

static const struct usbh_class_driver cdc_ecm_class_driver = {
    .driver_name = "cdc_ecm",
    .connect = usbh_cdc_ecm_connect,
    .disconnect = usbh_cdc_ecm_disconnect,
};

/* Match the RTL8153 by VID/PID on its config-1 vendor interface (class 0xFF).
 * CherryUSB's VID+PID+class match (usbh_core.c) fires for this combination. */
CLASS_INFO_DEFINE const struct usbh_class_info cdc_ecm_class_info = {
    .match_flags = USB_CLASS_MATCH_VENDOR | USB_CLASS_MATCH_PRODUCT | USB_CLASS_MATCH_INTF_CLASS,
    .class = 0xFF,
    .subclass = 0x00,
    .protocol = 0x00,
    .vid = CDC_ECM_RTL_VID,
    .pid = CDC_ECM_RTL_PID,
    .class_driver = &cdc_ecm_class_driver,
};
