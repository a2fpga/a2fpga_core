/*
 * usbh_cdc_ecm — in-tree CDC-ECM USB-Ethernet host driver for the a2n20v2
 * Enhanced BL616 host build.
 *
 * Target: RTL8153 USB-Ethernet adapters (Realtek VID 0x0BDA / PID 0x8153)
 * that expose a DUAL configuration:
 *   - config 1 = Realtek vendor protocol (class 0xFF)  <- what CherryUSB
 *                enumerates by default (it hardcodes SET_CONFIGURATION(1))
 *   - config 2 = standard CDC-ECM (Communications 0x02 / ECM subclass 0x06
 *                + CDC-Data 0x0A)
 *
 * Because the bundled CherryUSB (v0.10.0) only ever enumerates the FIRST
 * configuration, the stock CDC-ECM class match (INTF_CLASS=CDC) never fires
 * for this adapter. Instead this driver matches the adapter by VID/PID on its
 * config-1 vendor interface, then in connect() issues SET_CONFIGURATION(2),
 * fetches and parses the config-2 descriptor itself, activates the ECM
 * endpoints, and runs the CDC-ECM data path. All of this lives in our source
 * tree — the external bouffalo_sdk CherryUSB is left byte-for-byte unmodified.
 *
 * Derived from CherryUSB's usbh_cdc_ecm.c (Apache-2.0, (c) 2022 sakumisu);
 * the config-switch + manual descriptor parse are the in-tree additions.
 */
#ifndef USBH_CDC_ECM_H
#define USBH_CDC_ECM_H

#include "usbh_core.h"
#include "usb_cdc.h"

#include "lwip/netif.h"
#include "lwip/pbuf.h"

/* Realtek RTL8152/8153 family — matched on the config-1 vendor interface. */
#define CDC_ECM_RTL_VID 0x0BDA
#define CDC_ECM_RTL_PID 0x8153

#define CDC_ECM_NET_DISCONNECTED 0x00
#define CDC_ECM_NET_CONNECTED    0x01

#define CDC_ECM_ETH_MAX_SEGSZE 1514U

struct usbh_cdc_ecm {
    struct usbh_hubport *hport;

    uint8_t ctrl_intf; /* CDC control interface number (config 2) */
    uint8_t data_intf; /* CDC data interface number (config 2) */
    uint8_t data_altsetting; /* alt with the bulk endpoint pair */
    uint8_t mac[6];
    uint32_t max_segment_size;
    uint8_t connect_status;

    usbh_pipe_t bulkin;  /* Bulk IN  endpoint (USB -> host) */
    usbh_pipe_t bulkout; /* Bulk OUT endpoint (host -> USB) */
    usbh_pipe_t intin;   /* Interrupt IN endpoint (notifications) */
    struct usbh_urb bulkout_urb;
    struct usbh_urb bulkin_urb;
    struct usbh_urb intin_urb;

    struct netif *netif; /* lwIP netif bound to this adapter */
};

#ifdef __cplusplus
extern "C" {
#endif

/* Weak hooks, overridden by the lwIP glue (ecm_netif.c). run() is called once
 * the ECM data path is up; stop() on disconnect. */
void usbh_cdc_ecm_run(struct usbh_cdc_ecm *cdc_ecm_class);
void usbh_cdc_ecm_stop(struct usbh_cdc_ecm *cdc_ecm_class);

/* lwIP netif->linkoutput: transmit one pbuf chain on the bulk-OUT endpoint. */
err_t usbh_cdc_ecm_linkoutput(struct netif *netif, struct pbuf *p);

/* Spawn the bulk-IN RX thread that feeds received frames into netif->input. */
void usbh_cdc_ecm_lwip_thread_init(struct netif *netif);

/* Accessor for the (single) ECM class instance, NULL if none connected. */
struct usbh_cdc_ecm *usbh_cdc_ecm_get_class(void);

#ifdef __cplusplus
}
#endif

#endif /* USBH_CDC_ECM_H */
