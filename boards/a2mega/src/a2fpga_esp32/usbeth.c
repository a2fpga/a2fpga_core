/*
 * usbeth.c -- CDC-ECM / CDC-NCM host driver on ESP-IDF usb_host, with an
 * esp_netif for the ESP32's own IP and a MACRAW uplink for w5100.c.
 * See usbeth.h for the design; usbeth_proto.c holds the pure parsing.
 *
 * Task model:
 *   - usbhost.cpp's worker task calls usbeth_attach()/usbeth_detach(); the
 *     blocking control transfers happen there (never in the client task).
 *   - Bulk/interrupt completions run in the usb_host client task: they copy
 *     at most, re-arm, and never touch the FPGA link.
 *   - lwIP's tcpip thread calls netif_transmit(); the main loop calls
 *     usbeth_tx() and usbeth_poll(). Transfers are allocated per send and
 *     freed in their completion callback, so no shared TX buffer exists.
 */
#include "usbeth.h"
#include "usbeth_proto.h"
#include "w5100.h"
#include "wifi_bridge.h"      /* the pure MAC-NAT fixup helpers */
#include "osd_console.h"

#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#include "esp_log.h"
#include "esp_err.h"
#include "esp_timer.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_netif_defaults.h"
#include "esp_mac.h"
#include "usb/usb_host.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "usbeth";

/* ---- adapter state ------------------------------------------------------- */
typedef struct {
    usb_host_client_handle_t client;
    usb_device_handle_t      dev;
    uint16_t vid, pid;
    cdc_eth_fn_t fn;
    uint8_t  mac[6];
    uint8_t  host_intf[2];        /* interfaces claimed from the host library (active configuration) */
    uint8_t  n_host;
    uint8_t  alt_cfg;             /* != 0: device switched to this configuration (see usbeth_attach_alt) */
    usb_transfer_t *xin;          /* the one outstanding bulk IN */
    usb_transfer_t *xnotify;      /* the one outstanding interrupt IN (or NULL) */
    size_t   rx_size;             /* bulk IN transfer size (MPS multiple) */
    ncm_ntb_params_t ntb;         /* NCM only */
    uint16_t ntb_seq;
    int64_t  attach_us;
} eth_dev_t;

static eth_dev_t     s_e;
static volatile bool s_present;        /* s_e configured and transfers armed */
static volatile bool s_link_up;        /* carrier (notification or assumed) */
static volatile bool s_link_known;     /* a NETWORK_CONNECTION arrived */
static bool          s_netif_link;     /* link state last applied to the netif (main loop) */
static volatile bool s_bridging = true;
static uint8_t       s_apple_mac[6];
static bool          s_apple_valid;

/* esp_netif */
typedef struct { esp_netif_driver_base_t base; } usbeth_drv_t;
static usbeth_drv_t  s_drv;
static esp_netif_t  *s_netif;
static volatile bool s_netif_started;
static volatile bool s_got_ip;
static volatile uint32_t s_ip;

/* counters (CLI) */
static volatile uint32_t s_rx_frames, s_tx_frames, s_rx_apple, s_tx_apple;
static volatile uint32_t s_rx_drop_ring, s_tx_err, s_tx_inflight;
#define TX_INFLIGHT_MAX 8

/* ---- ingress SPSC ring (producer: client task, consumer: main loop) ---- */
#define ER_SLOTS 8
#define ER_MASK  (ER_SLOTS - 1)
typedef struct { uint16_t len; uint8_t buf[W5100_MAX_FRAME]; } rx_slot_t;
static rx_slot_t s_rx[ER_SLOTS];
static uint32_t  s_rx_head, s_rx_tail;

/* main-loop log requests (set in callbacks, printed from usbeth_poll) */
static volatile uint8_t s_pending_log;   /* bit0 link up, bit1 link down, bit2 got ip, bit3 lost ip */

static inline int64_t now_ms(void) { return esp_timer_get_time() / 1000; }

/* =========================================================================
 * Control transfers (blocking; worker task only)
 * ========================================================================= */
static void ctrl_done_cb(usb_transfer_t *t) { xTaskNotifyGive((TaskHandle_t)t->context); }

static esp_err_t ctrl_xfer(uint8_t bmRT, uint8_t bReq, uint16_t wVal, uint16_t wIdx,
                           uint16_t wLen, uint8_t *data, size_t *got)
{
    usb_transfer_t *t = NULL;
    if (usb_host_transfer_alloc(sizeof(usb_setup_packet_t) + wLen, 0, &t) != ESP_OK) return ESP_ERR_NO_MEM;
    usb_setup_packet_t *sp = (usb_setup_packet_t *)t->data_buffer;
    sp->bmRequestType = bmRT; sp->bRequest = bReq; sp->wValue = wVal; sp->wIndex = wIdx; sp->wLength = wLen;
    if (data && !(bmRT & 0x80) && wLen) memcpy(t->data_buffer + sizeof(*sp), data, wLen);
    t->num_bytes = sizeof(*sp) + wLen; t->device_handle = s_e.dev; t->bEndpointAddress = 0;
    t->callback = ctrl_done_cb; t->context = (void *)xTaskGetCurrentTaskHandle(); t->timeout_ms = 1000;
    ulTaskNotifyTake(pdTRUE, 0);
    esp_err_t r = usb_host_transfer_submit_control(s_e.client, t);
    if (r == ESP_OK) {
        if (!ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(1500))) r = ESP_ERR_TIMEOUT;
        else {
            r = (t->status == USB_TRANSFER_STATUS_COMPLETED) ? ESP_OK : ESP_FAIL;
            size_t n = t->actual_num_bytes > (int)(sizeof(*sp) + wLen) ? wLen
                     : (t->actual_num_bytes > (int)sizeof(*sp) ? t->actual_num_bytes - sizeof(*sp) : 0);
            if (r == ESP_OK && data && (bmRT & 0x80)) memcpy(data, t->data_buffer + sizeof(*sp), n);
            if (got) *got = n;
        }
    }
    if (r == ESP_ERR_TIMEOUT) return r;      /* transfer may still complete later: leak rather than crash */
    usb_host_transfer_free(t);
    return r;
}

/* =========================================================================
 * esp_netif glue (ESP32's own IP on the wire)
 * ========================================================================= */
static esp_err_t submit_out(const uint8_t *buf, size_t len);

static esp_err_t netif_transmit(void *h, void *buffer, size_t len)
{
    (void)h;
    if (!s_present || !s_link_up) return ESP_FAIL;
    return submit_out((const uint8_t *)buffer, len);
}
static void netif_free_rx(void *h, void *buffer) { (void)h; free(buffer); }

static esp_err_t netif_post_attach(esp_netif_t *netif, esp_netif_iodriver_handle h)
{
    usbeth_drv_t *d = (usbeth_drv_t *)h;
    d->base.netif = netif;
    esp_netif_driver_ifconfig_t cfg = {
        .handle = d,
        .transmit = netif_transmit,
        .transmit_wrap = NULL,
        .driver_free_rx_buffer = netif_free_rx,
        .driver_set_mac_filter = NULL,
    };
    return esp_netif_set_driver_config(netif, &cfg);
}

static void on_ip_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg; (void)base;
    if (id == IP_EVENT_ETH_GOT_IP) {
        const ip_event_got_ip_t *e = (const ip_event_got_ip_t *)data;
        if (e->esp_netif != s_netif) return;
        s_ip = e->ip_info.ip.addr; s_got_ip = true; s_pending_log |= 0x04;
        ESP_LOGI(TAG, "ESP32 wired ip " IPSTR, IP2STR(&e->ip_info.ip));
    } else if (id == IP_EVENT_ETH_LOST_IP) {
        const ip_event_got_ip_t *e = (const ip_event_got_ip_t *)data;
        if (e && e->esp_netif != s_netif) return;
        s_got_ip = false; s_ip = 0; s_pending_log |= 0x08;
    }
}

static bool netif_ensure(const uint8_t mac[6])
{
    if (!s_netif) {
        esp_err_t err = esp_netif_init();
        if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) { ESP_LOGE(TAG, "esp_netif_init: %s", esp_err_to_name(err)); return false; }
        err = esp_event_loop_create_default();
        if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) { ESP_LOGE(TAG, "event loop: %s", esp_err_to_name(err)); return false; }

        esp_netif_inherent_config_t base = ESP_NETIF_INHERENT_DEFAULT_ETH();
        base.if_key = "USB_ETH";
        base.if_desc = "usbeth";
        base.route_prio = 120;          /* above WIFI_STA (100): prefer the wire */
        esp_netif_config_t cfg = { .base = &base, .driver = NULL, .stack = ESP_NETIF_NETSTACK_DEFAULT_ETH };
        s_netif = esp_netif_new(&cfg);
        if (!s_netif) { ESP_LOGE(TAG, "esp_netif_new failed"); return false; }
        s_drv.base.post_attach = netif_post_attach;
        if (esp_netif_attach(s_netif, &s_drv) != ESP_OK) { ESP_LOGE(TAG, "esp_netif_attach failed"); return false; }
        esp_event_handler_instance_register(IP_EVENT, ESP_EVENT_ANY_ID, on_ip_event, NULL, NULL);
    }
    esp_netif_set_mac(s_netif, (uint8_t *)mac);
    return true;
}

static void netif_link(bool up)
{
    if (!s_netif) return;
    if (up) {
        if (!s_netif_started) { esp_netif_action_start(s_netif, NULL, 0, NULL); s_netif_started = true; }
        esp_netif_action_connected(s_netif, NULL, 0, NULL);     /* starts the DHCP client */
    } else {
        if (s_netif_started) esp_netif_action_disconnected(s_netif, NULL, 0, NULL);
        s_got_ip = false; s_ip = 0;
    }
}

static void netif_stop(void)
{
    if (s_netif && s_netif_started) {
        esp_netif_action_disconnected(s_netif, NULL, 0, NULL);
        esp_netif_action_stop(s_netif, NULL, 0, NULL);
        s_netif_started = false;
    }
    s_got_ip = false; s_ip = 0;
}

/* =========================================================================
 * Bulk OUT (any task; non-blocking, transfer freed in the callback)
 * ========================================================================= */
static void out_done_cb(usb_transfer_t *t)
{
    if (t->status != USB_TRANSFER_STATUS_COMPLETED) s_tx_err++;
    else s_tx_frames++;
    __atomic_sub_fetch(&s_tx_inflight, 1, __ATOMIC_RELAXED);
    usb_host_transfer_free(t);
}

static esp_err_t submit_out(const uint8_t *buf, size_t len)
{
    if (!s_present || !len) return ESP_FAIL;
    if (__atomic_load_n(&s_tx_inflight, __ATOMIC_RELAXED) >= TX_INFLIGHT_MAX) { s_tx_err++; return ESP_ERR_NO_MEM; }
    size_t need = s_e.fn.ncm ? (len + 64 + 2 * s_e.ntb.out_align + s_e.ntb.out_div) : len;
    usb_transfer_t *t = NULL;
    if (usb_host_transfer_alloc(need, 0, &t) != ESP_OK) { s_tx_err++; return ESP_ERR_NO_MEM; }
    size_t n;
    if (s_e.fn.ncm) {
        n = ncm_ntb16_build(t->data_buffer, need, buf, (uint16_t)len, s_e.ntb_seq++, &s_e.ntb);
        if (!n) { usb_host_transfer_free(t); s_tx_err++; return ESP_FAIL; }
    } else {
        memcpy(t->data_buffer, buf, len); n = len;
    }
    t->num_bytes = (int)n; t->device_handle = s_e.dev; t->bEndpointAddress = s_e.fn.ep_out;
    t->callback = out_done_cb; t->context = NULL; t->timeout_ms = 1000;
    t->flags = USB_TRANSFER_FLAG_ZERO_PACK;        /* ECM/NCM: short-packet terminate */
    __atomic_add_fetch(&s_tx_inflight, 1, __ATOMIC_RELAXED);
    esp_err_t r = usb_host_transfer_submit(t);
    if (r != ESP_OK) { __atomic_sub_fetch(&s_tx_inflight, 1, __ATOMIC_RELAXED); usb_host_transfer_free(t); s_tx_err++; }
    return r;
}

/* =========================================================================
 * Receive path (client task)
 * ========================================================================= */
static void deliver_frame(const uint8_t *f, uint16_t len)
{
    if (len < 14 || len > W5100_MAX_FRAME) return;
    s_rx_frames++;

    /* 1. ESP32's own stack (zero-copy custom pbuf; freed via netif_free_rx) */
    if (s_netif_started) {
        uint8_t *copy = (uint8_t *)malloc(len);
        if (copy) {
            memcpy(copy, f, len);
            if (esp_netif_receive(s_netif, copy, len, copy) != ESP_OK) { /* freed by esp_netif */ }
        }
    }

    /* 2. Apple II: broadcast/multicast or unicast to the adapter MAC */
    if (s_bridging && w5100_macraw_active()) {
        bool mcast = (f[0] & 0x01) != 0;
        bool tous  = memcmp(f, s_e.mac, 6) == 0;
        if (mcast || tous) {
            uint32_t head = __atomic_load_n(&s_rx_head, __ATOMIC_RELAXED);
            uint32_t tail = __atomic_load_n(&s_rx_tail, __ATOMIC_ACQUIRE);
            if (head - tail < ER_SLOTS) {
                rx_slot_t *slot = &s_rx[head & ER_MASK];
                memcpy(slot->buf, f, len); slot->len = len;
                __atomic_store_n(&s_rx_head, head + 1, __ATOMIC_RELEASE);
            } else {
                s_rx_drop_ring++;
            }
        }
    }
}

static void ncm_dgram_cb(void *ctx, const uint8_t *frame, uint16_t len) { (void)ctx; deliver_frame(frame, len); }

static void in_done_cb(usb_transfer_t *t)
{
    if (!s_present || t != s_e.xin) return;
    if (t->status == USB_TRANSFER_STATUS_COMPLETED) {
        if (t->actual_num_bytes > 0) {
            if (s_e.fn.ncm) ncm_ntb16_parse(t->data_buffer, (size_t)t->actual_num_bytes, ncm_dgram_cb, NULL);
            else            deliver_frame(t->data_buffer, (uint16_t)t->actual_num_bytes);
        }
    } else if (t->status != USB_TRANSFER_STATUS_TIMED_OUT &&
               t->status != USB_TRANSFER_STATUS_OVERFLOW) {
        ESP_LOGW(TAG, "bulk IN stopped: status %d", (int)t->status);
        return;                                   /* device gone / stalled: stop re-arming */
    }
    t->num_bytes = (int)s_e.rx_size;
    if (usb_host_transfer_submit(t) != ESP_OK) ESP_LOGW(TAG, "bulk IN re-arm failed");
}

static void notify_done_cb(usb_transfer_t *t)
{
    if (!s_present || t != s_e.xnotify) return;
    if (t->status == USB_TRANSFER_STATUS_COMPLETED && t->actual_num_bytes >= 8) {
        const uint8_t *n = t->data_buffer;
        if (n[1] == CDC_NOTIFY_NETWORK_CONNECTION) {
            bool up = (n[2] | n[3]) != 0;
            s_link_known = true;
            if (up != s_link_up) {
                s_link_up = up;                 /* netif follows in usbeth_poll() */
                s_pending_log |= up ? 0x01 : 0x02;
            }
        }
        /* CONNECTION_SPEED_CHANGE: informational */
    } else if (t->status != USB_TRANSFER_STATUS_COMPLETED &&
               t->status != USB_TRANSFER_STATUS_TIMED_OUT) {
        return;
    }
    t->num_bytes = (int)((16 + s_e.fn.mps_notify - 1) / s_e.fn.mps_notify * s_e.fn.mps_notify);
    usb_host_transfer_submit(t);
}

/* =========================================================================
 * Attach / detach (worker task)
 * ========================================================================= */
/* usb_host_transfer_free() refuses an in-flight transfer; after a detach
 * the host library completes it (NO_DEVICE) within a few event-pump
 * rounds, so wait for that rather than racing the completion callback
 * (which never frees: it only stops re-arming once s_present is false). */
static void free_when_idle(usb_transfer_t **pt)
{
    if (!*pt) return;
    for (int i = 0; i < 50 && usb_host_transfer_free(*pt) != ESP_OK; i++)
        vTaskDelay(pdMS_TO_TICKS(10));
    *pt = NULL;
}

static void release_all(void)
{
    free_when_idle(&s_e.xin);
    free_when_idle(&s_e.xnotify);
    while (s_e.n_host) usb_host_interface_release(s_e.client, s_e.dev, s_e.host_intf[--s_e.n_host]);
}

static bool claim_host_intf(uint8_t intf, uint8_t alt)
{
    if (s_e.n_host >= 2) return false;
    if (usb_host_interface_claim(s_e.client, s_e.dev, intf, alt) != ESP_OK) {
        ESP_LOGW(TAG, "claim interface %u alt %u failed", intf, alt);
        return false;
    }
    s_e.host_intf[s_e.n_host++] = intf;
    return true;
}

/* Everything after the host-side interface claims: MAC, NCM parameters,
 * SET_INTERFACE + packet filter on the device, netif, armed transfers.
 * s_e.fn describes the function in the configuration the DEVICE is in. */
static bool start_function(void)
{
    const cdc_eth_fn_t *fn = &s_e.fn;
    /* MAC address: iMACAddress string; fall back to a locally administered
     * address derived from the ESP32's base MAC so the bridge still runs. */
    bool have_mac = false;
    if (fn->imac) {
        uint8_t sd[64]; size_t got = 0;
        if (ctrl_xfer(0x80, 0x06, (uint16_t)(0x0300 | fn->imac), 0x0409, sizeof(sd), sd, &got) == ESP_OK)
            have_mac = cdc_parse_mac_string(sd, got, s_e.mac);
    }
    if (!have_mac) {
        esp_read_mac(s_e.mac, ESP_MAC_WIFI_STA);
        s_e.mac[0] = (uint8_t)((s_e.mac[0] | 0x02) & 0xFE);   /* locally administered, unicast */
        s_e.mac[5] ^= 0x5A;
        ESP_LOGW(TAG, "no MAC string from adapter; using derived LAA");
    }

    if (fn->ncm) {
        uint8_t pb[28]; size_t got = 0;
        if (ctrl_xfer(0xA1, CDC_REQ_GET_NTB_PARAMETERS, 0, fn->ctrl_intf, sizeof(pb), pb, &got) != ESP_OK ||
            !ncm_parse_ntb_params(pb, got, &s_e.ntb)) {
            ESP_LOGW(TAG, "GET_NTB_PARAMETERS failed"); return false;
        }
        /* Keep the IN NTB small (the spec minimum); frames arrive one per NTB anyway at FS */
        uint32_t in_size = 2048;
        if (s_e.ntb.in_max && s_e.ntb.in_max < in_size) in_size = s_e.ntb.in_max;
        uint8_t sz[4] = { (uint8_t)in_size, (uint8_t)(in_size >> 8), (uint8_t)(in_size >> 16), (uint8_t)(in_size >> 24) };
        if (ctrl_xfer(0x21, CDC_REQ_SET_NTB_INPUT_SIZE, 0, fn->ctrl_intf, 4, sz, NULL) != ESP_OK)
            ESP_LOGW(TAG, "SET_NTB_INPUT_SIZE refused (continuing with %lu)", (unsigned long)s_e.ntb.in_max);
        else s_e.ntb.in_max = in_size;
        if (s_e.ntb.formats & 0x02)   /* device also speaks NTB32: pin it to NTB16 */
            ctrl_xfer(0x21, CDC_REQ_SET_NTB_FORMAT, 0, fn->ctrl_intf, 0, NULL, NULL);
        s_e.rx_size = s_e.ntb.in_max ? s_e.ntb.in_max : 2048;
    } else {
        s_e.rx_size = 1536;                                    /* >= 1518, multiple of 64 */
    }
    s_e.rx_size = (s_e.rx_size + fn->mps_in - 1) / fn->mps_in * fn->mps_in;

    /* Activate the data interface (alt 0 carries no endpoints) and open the
     * receive filter. Some adapters STALL the filter request; harmless. */
    if (ctrl_xfer(0x01, 0x0B, fn->data_alt, fn->data_intf, 0, NULL, NULL) != ESP_OK)
        ESP_LOGW(TAG, "SET_INTERFACE(%u,%u) refused", fn->data_intf, fn->data_alt);
    ctrl_xfer(0x21, CDC_REQ_SET_ETHERNET_PACKET_FILTER,
              CDC_PKT_DIRECTED | CDC_PKT_BROADCAST | CDC_PKT_ALL_MULTICAST, fn->ctrl_intf, 0, NULL, NULL);

    if (!netif_ensure(s_e.mac)) return false;

    /* Arm the receive transfers */
    if (usb_host_transfer_alloc(s_e.rx_size, 0, &s_e.xin) != ESP_OK) return false;
    s_e.xin->device_handle = s_e.dev; s_e.xin->bEndpointAddress = fn->ep_in;
    s_e.xin->num_bytes = (int)s_e.rx_size; s_e.xin->callback = in_done_cb; s_e.xin->timeout_ms = 0;
    if (fn->ep_notify) {
        size_t nsz = (16 + fn->mps_notify - 1) / fn->mps_notify * fn->mps_notify;
        if (usb_host_transfer_alloc(nsz, 0, &s_e.xnotify) == ESP_OK) {
            s_e.xnotify->device_handle = s_e.dev; s_e.xnotify->bEndpointAddress = fn->ep_notify;
            s_e.xnotify->num_bytes = (int)nsz; s_e.xnotify->callback = notify_done_cb; s_e.xnotify->timeout_ms = 0;
        }
    }
    s_rx_head = s_rx_tail = 0;
    s_link_up = false; s_link_known = false; s_netif_link = false;
    s_e.attach_us = esp_timer_get_time();
    s_present = true;
    if (s_e.xnotify && usb_host_transfer_submit(s_e.xnotify) != ESP_OK) { usb_host_transfer_free(s_e.xnotify); s_e.xnotify = NULL; }
    if (usb_host_transfer_submit(s_e.xin) != ESP_OK) { ESP_LOGW(TAG, "bulk IN submit failed"); s_present = false; return false; }

    if (s_e.alt_cfg)
        osd_log("USB ETH: %04X:%04X %s CFG %u %02X:%02X:%02X:%02X:%02X:%02X", s_e.vid, s_e.pid, fn->ncm ? "NCM" : "ECM",
                s_e.alt_cfg, s_e.mac[0], s_e.mac[1], s_e.mac[2], s_e.mac[3], s_e.mac[4], s_e.mac[5]);
    else
        osd_log("USB ETH: %04X:%04X %s %02X:%02X:%02X:%02X:%02X:%02X", s_e.vid, s_e.pid, fn->ncm ? "NCM" : "ECM",
                s_e.mac[0], s_e.mac[1], s_e.mac[2], s_e.mac[3], s_e.mac[4], s_e.mac[5]);
    return true;
}

bool usbeth_attach(void *client, void *dev, const uint8_t *cfg, size_t cfg_len,
                   uint8_t ctrl_intf, uint16_t vid, uint16_t pid)
{
    if (s_present || s_e.dev) { ESP_LOGW(TAG, "adapter already attached; ignoring %04X:%04X", vid, pid); return false; }
    memset(&s_e, 0, sizeof(s_e));
    s_e.client = (usb_host_client_handle_t)client;
    s_e.dev    = (usb_device_handle_t)dev;
    s_e.vid = vid; s_e.pid = pid;

    if (!cdc_parse_eth_function(cfg, cfg_len, ctrl_intf, &s_e.fn) || !s_e.fn.data_found) {
        ESP_LOGW(TAG, "%04X:%04X: CDC interface %u has no usable Ethernet function", vid, pid, ctrl_intf);
        memset(&s_e, 0, sizeof(s_e));
        return false;
    }
    const cdc_eth_fn_t *fn = &s_e.fn;
    ESP_LOGI(TAG, "%s ctrl %u data %u alt %u in %02X/%u out %02X/%u notify %02X imac %u",
             fn->ncm ? "NCM" : "ECM", fn->ctrl_intf, fn->data_intf, fn->data_alt,
             fn->ep_in, fn->mps_in, fn->ep_out, fn->mps_out, fn->ep_notify, fn->imac);

    /* Data interface first (two bulk pipes, essential). The control
     * interface's notification pipe is a nicety: with the ESP32-S3's eight
     * host channels shared by hub, stick and this adapter it may not fit, and
     * the class requests reach the control interface through EP0 anyway. */
    if (!claim_host_intf(fn->data_intf, fn->data_alt)) {
        osd_log("USB ETH: %04X:%04X: NO HOST CHANNELS", vid, pid);
        goto fail;
    }
    if (fn->ep_notify && !claim_host_intf(fn->ctrl_intf, 0)) {
        ESP_LOGW(TAG, "no host channel for the notification pipe; link assumed up");
        s_e.fn.ep_notify = 0;
    }
    if (!start_function()) goto fail;
    return true;

fail:
    release_all();
    memset(&s_e, 0, sizeof(s_e));
    return false;
}

/* Dual-configuration adapters (Realtek RTL8152/RTL8153 and kin): the host
 * library enumerated configuration 1 (vendor-specific, nothing we drive) and
 * cannot be asked for another one (its enumeration filter is compiled out
 * of the Arduino libraries, and usbh_dev_set_config_desc() only accepts a
 * descriptor while the device is still in the addressed state). So:
 *   1. read the other configurations ourselves and find an ECM/NCM function;
 *   2. SET_CONFIGURATION on the device;
 *   3. overwrite the library's cached copy of the active configuration (the
 *      buffer usb_host_get_active_config_descriptor() points at, which the
 *      library parses on every interface claim/release) with a 32-byte
 *      configuration that lists only the function's data interface and its
 *      two bulk endpoints -- it always fits, a vendor configuration with a
 *      bulk pair is at least that long;
 *   4. claim that data interface: exactly two pipes.
 * Nothing else in the library reads that buffer afterwards (it is freed
 * with the device). The CDC control requests go to the control interface
 * through EP0 and need no claim. No notification pipe: the ESP32-S3 has
 * eight host channels (one per pipe, for the life of the device), and with
 * a hub (2) and a stick (3) the adapter gets EP0 + two bulk = 3; the link is
 * assumed up after USBETH_LINK_ASSUME_MS. */
bool usbeth_attach_alt(void *client, void *dev, const uint8_t *active, size_t active_len,
                       uint8_t num_configs, uint16_t vid, uint16_t pid)
{
    if (s_present || s_e.dev) return false;
    if (num_configs < 2 || active_len < CDC_MIN_CONFIG_LEN) return false;
    memset(&s_e, 0, sizeof(s_e));
    s_e.client = (usb_host_client_handle_t)client;
    s_e.dev    = (usb_device_handle_t)dev;
    s_e.vid = vid; s_e.pid = pid;

    static uint8_t cfgbuf[512];
    uint8_t saved[CDC_MIN_CONFIG_LEN], synth[CDC_MIN_CONFIG_LEN];
    for (uint8_t cv = 2; cv <= num_configs && cv <= 4; cv++) {
        size_t got = 0;
        if (ctrl_xfer(0x80, 0x06, (uint16_t)(0x0200 | (cv - 1)), 0, 9, cfgbuf, &got) != ESP_OK || got < 9) continue;
        size_t total = (size_t)(cfgbuf[2] | (cfgbuf[3] << 8));
        if (total < 9 || total > sizeof(cfgbuf)) continue;
        if (ctrl_xfer(0x80, 0x06, (uint16_t)(0x0200 | (cv - 1)), 0, (uint16_t)total, cfgbuf, &got) != ESP_OK || got < total) continue;
        cdc_eth_fn_t fn;
        if (!cdc_find_eth_function(cfgbuf, total, &fn)) continue;
        if (!cdc_build_min_config(&fn, cv, synth, sizeof(synth))) continue;

        if (ctrl_xfer(0x00, 0x09, cv, 0, 0, NULL, NULL) != ESP_OK) {         /* SET_CONFIGURATION */
            ESP_LOGW(TAG, "SET_CONFIGURATION(%u) failed", cv);
            continue;
        }
        vTaskDelay(pdMS_TO_TICKS(20));
        memcpy(saved, active, CDC_MIN_CONFIG_LEN);
        memcpy((void *)active, synth, CDC_MIN_CONFIG_LEN);                   /* see the comment above */
        s_e.fn = fn;
        s_e.fn.ep_notify = 0;
        s_e.alt_cfg = cv;
        ESP_LOGI(TAG, "%04X:%04X: switched to configuration %u (%s), data interface %u alt %u",
                 vid, pid, cv, fn.ncm ? "NCM" : "ECM", fn.data_intf, fn.data_alt);
        if (!claim_host_intf(fn.data_intf, fn.data_alt)) {
            osd_log("USB ETH: %04X:%04X CFG %u: NO HOST CHANNELS", vid, pid, cv);
            goto fail;
        }
        if (!start_function()) goto fail;
        return true;

fail:
        release_all();
        memcpy((void *)active, saved, CDC_MIN_CONFIG_LEN);
        ctrl_xfer(0x00, 0x09, 1, 0, 0, NULL, NULL);  /* back to the configuration the library believes in */
        memset(&s_e, 0, sizeof(s_e));
        return false;
    }
    memset(&s_e, 0, sizeof(s_e));
    return false;
}

void usbeth_detach(void *dev)
{
    if (!s_e.dev || s_e.dev != (usb_device_handle_t)dev) return;
    s_present = false;
    s_link_up = false; s_link_known = false; s_netif_link = false;
    netif_stop();
    release_all();
    memset(&s_e, 0, sizeof(s_e));
    s_rx_head = s_rx_tail = 0;
    osd_log("USB ETH: ADAPTER REMOVED");
}

/* =========================================================================
 * Main loop
 * ========================================================================= */
void usbeth_poll(void)
{
    if (s_present && !s_link_known && !s_link_up &&
        esp_timer_get_time() - s_e.attach_us > (int64_t)USBETH_LINK_ASSUME_MS * 1000) {
        /* no NETWORK_CONNECTION notification: treat the link as up */
        s_link_up = true;
        s_pending_log |= 0x01;
    }
    /* Apply link changes to the netif here (main loop), not in the USB
     * client task: the esp_netif actions round-trip through the lwIP
     * thread and must not stall the transfer completion pump. */
    if (s_present && s_link_up != s_netif_link) {
        s_netif_link = s_link_up;
        netif_link(s_netif_link);
    }

    uint8_t lg = s_pending_log;
    if (lg) {
        s_pending_log = 0;
        if (lg & 0x01) osd_log("USB ETH: LINK UP%s", s_link_known ? "" : " (ASSUMED)");
        if (lg & 0x02) osd_log("USB ETH: LINK DOWN");
        if (lg & 0x04) { uint32_t ip = s_ip; osd_log("USB ETH: IP %u.%u.%u.%u", ip & 0xFF, (ip >> 8) & 0xFF, (ip >> 16) & 0xFF, ip >> 24); }
        if (lg & 0x08) osd_log("USB ETH: IP LOST");
    }

    uint32_t tail = __atomic_load_n(&s_rx_tail, __ATOMIC_RELAXED);
    uint32_t head = __atomic_load_n(&s_rx_head, __ATOMIC_ACQUIRE);
    while (tail != head) {
        rx_slot_t *slot = &s_rx[tail & ER_MASK];
        uint8_t apple[6];
        bool have_apple = s_apple_valid ? (memcpy(apple, s_apple_mac, 6), true) : w5100_get_mac(apple);
        if (have_apple && s_present)
            wifi_bridge_fixup_ingress(slot->buf, slot->len, apple, s_e.mac);
        w5100_macraw_rx(slot->buf, slot->len);
        s_rx_apple++;
        tail++;
        __atomic_store_n(&s_rx_tail, tail, __ATOMIC_RELEASE);
        head = __atomic_load_n(&s_rx_head, __ATOMIC_ACQUIRE);
    }
}

/* =========================================================================
 * Uplink interface
 * ========================================================================= */
bool usbeth_present(void)  { return s_present; }
bool usbeth_link_up(void)  { return s_present && s_link_up; }
bool usbeth_got_ip(void)   { return s_present && s_got_ip; }
uint32_t usbeth_ip(void)   { return s_present ? s_ip : 0; }
bool usbeth_mac(uint8_t mac[6]) { if (!s_present) return false; memcpy(mac, s_e.mac, 6); return true; }
void usbeth_set_bridging(bool on) { s_bridging = on; }

void usbeth_set_apple_mac(const uint8_t mac[6])
{
    memcpy(s_apple_mac, mac, 6);
    s_apple_valid = (mac[0] | mac[1] | mac[2] | mac[3] | mac[4] | mac[5]) != 0;
}

void usbeth_tx(const uint8_t *frame, uint32_t len)
{
    if (!s_present || !s_link_up || len < 14 || len > W5100_MAX_FRAME) return;
    static uint8_t buf[W5100_MAX_FRAME];    /* main-loop task only */
    memcpy(buf, frame, len);
    uint8_t apple[6];
    const uint8_t *inner = s_e.mac;          /* unknown SHAR: ARP compare is a no-op */
    if (s_apple_valid) inner = s_apple_mac;
    else if (w5100_get_mac(apple)) inner = apple;
    wifi_bridge_fixup_egress(buf, (uint16_t)len, inner, s_e.mac);
    if (submit_out(buf, len) == ESP_OK) s_tx_apple++;
}

void usbeth_apple_counts(uint32_t *rx, uint32_t *tx)
{
    if (rx) *rx = s_rx_apple;
    if (tx) *tx = s_tx_apple;
}

void usbeth_status(char *buf, size_t cap)
{
    if (!s_present) { snprintf(buf, cap, "USB ETH: no adapter"); return; }
    uint32_t ip = s_ip;
    snprintf(buf, cap, "USB ETH: %04X:%04X %s mac %02X:%02X:%02X:%02X:%02X:%02X link %s ip %u.%u.%u.%u rx %lu (a2 %lu, drop %lu) tx %lu (a2 %lu, err %lu)",
             s_e.vid, s_e.pid, s_e.fn.ncm ? "NCM" : "ECM",
             s_e.mac[0], s_e.mac[1], s_e.mac[2], s_e.mac[3], s_e.mac[4], s_e.mac[5],
             s_link_up ? (s_link_known ? "UP" : "UP?") : "DOWN",
             ip & 0xFF, (ip >> 8) & 0xFF, (ip >> 16) & 0xFF, ip >> 24,
             (unsigned long)s_rx_frames, (unsigned long)s_rx_apple, (unsigned long)s_rx_drop_ring,
             (unsigned long)s_tx_frames, (unsigned long)s_tx_apple, (unsigned long)s_tx_err);
}
