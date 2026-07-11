/*
 * wifi_bridge.c -- WiFi STA uplink for the W5100 MACRAW bridge (a2mega ESP32).
 * See wifi_bridge.h for the MAC-NAT architecture and the exact rewrite rules.
 *
 * Task model:
 *   - The WiFi driver task delivers frames to bridge_rxcb(); it only copies the
 *     ones the bridge wants into a lock-free SPSC ring and forwards every frame
 *     to esp_netif_receive() so the ESP32's own lwIP keeps working.
 *   - wifi_bridge_poll() (main loop, same task as w5100_poll) drains the ring,
 *     applies ingress MAC NAT, and hands frames to w5100_macraw_rx(), which
 *     does the (slow) FPGA-link writes outside the WiFi task.
 *   - w5100_bridge_tx() runs in the main loop (called from w5100_poll's SEND
 *     handler): egress MAC NAT + esp_wifi_internal_tx().
 */

#include "wifi_bridge.h"
#include "w5100.h"

#include <string.h>

#include "esp_log.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_private/wifi.h"   /* esp_wifi_internal_tx / _reg_rxcb (precompiled IDF) */
#include "nvs_flash.h"

static const char *TAG = "wifi_br";

/* ---- bridge state ---- */
static bool         s_started;          /* esp_wifi_start succeeded */
static volatile bool s_link_up;         /* associated (L2 usable for raw TX) */
static volatile bool s_got_ip;          /* ESP32's own DHCP lease obtained */
static volatile uint32_t s_ip;          /* ESP32's own IPv4, network byte order */
static uint8_t      s_sta_mac[6];       /* ESP32 station MAC (NAT outer MAC) */
static uint8_t      s_apple_mac[6];     /* Apple II SHAR (NAT inner MAC) */
static bool         s_apple_valid;
static char         s_ssid[33];
static esp_netif_t *s_netif;

/* Static IP config (wifi.txt lines 3-5 / menu Network screen). When
 * s_use_static is false the DHCP client runs. */
static bool         s_use_static;
static bool         s_static_applied;   /* status flag for net_connected() */
static uint8_t      s_cfg_ip[4], s_cfg_mask[4], s_cfg_gw[4];

/* Diagnostics */
static volatile uint32_t s_rx_drop_ring;   /* ingress dropped: SPSC ring full */
static volatile uint32_t s_tx_err;         /* esp_wifi_internal_tx failures */

/* ---- ingress SPSC ring (producer: WiFi task, consumer: main loop) ---- */
#define BR_RX_SLOTS 8               /* power of two */
#define BR_RX_MASK  (BR_RX_SLOTS - 1)
typedef struct {
    uint16_t len;
    uint8_t  buf[W5100_MAX_FRAME];
} rx_slot_t;
static rx_slot_t s_rx[BR_RX_SLOTS];
static uint32_t  s_rx_head;         /* written by producer only */
static uint32_t  s_rx_tail;         /* written by consumer only */

/* Egress scratch (main-loop task only; w5100_bridge_tx gets a const frame) */
static uint8_t s_tx_buf[W5100_MAX_FRAME];

/* =========================================================================
 * Pure frame-fixup helpers (no ESP dependencies; unit-testable)
 * Ethernet header: dst[0-5] src[6-11] ethertype[12-13]; payload at 14.
 * ARP payload:   htype[14-15] ptype[16-17] hlen[18] plen[19] oper[20-21]
 *                SHA[22-27] SPA[28-31] THA[32-37] TPA[38-41]
 * ========================================================================= */

static inline uint16_t rd_be16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }

/* Locate an unfragmented IPv4/UDP header. Returns the UDP header offset or 0. */
static uint16_t ipv4_udp_offset(const uint8_t *frame, uint16_t len)
{
    if (len < 14 + 20 || rd_be16(frame + 12) != 0x0800) return 0;
    uint8_t vihl = frame[14];
    if ((vihl >> 4) != 4) return 0;
    uint16_t ihl = (uint16_t)((vihl & 0x0F) * 4);
    if (ihl < 20 || len < (uint16_t)(14 + ihl + 8)) return 0;
    if (frame[14 + 9] != 17) return 0;                       /* not UDP */
    if ((rd_be16(frame + 14 + 6) & 0x1FFF) != 0) return 0;   /* non-first fragment */
    return (uint16_t)(14 + ihl);
}

bool wifi_bridge_fixup_egress(uint8_t *frame, uint16_t len,
                              const uint8_t apple_mac[6], const uint8_t sta_mac[6])
{
    if (len < 14) return false;
    bool changed = false;

    /* 1. Source MAC -> STA MAC (802.11 STA links only pass the station MAC) */
    if (memcmp(frame + 6, sta_mac, 6) != 0) {
        memcpy(frame + 6, sta_mac, 6);
        changed = true;
    }

    uint16_t ethertype = rd_be16(frame + 12);

    /* 2. ARP: rewrite sender-hardware-address when it is the Apple II MAC */
    if (ethertype == 0x0806 && len >= 42) {
        if (memcmp(frame + 22, apple_mac, 6) == 0 &&
            memcmp(frame + 22, sta_mac, 6) != 0) {
            memcpy(frame + 22, sta_mac, 6);
            changed = true;
        }
        return changed;
    }

    /* 3. DHCP client->server (UDP 68->67): force the BOOTP broadcast flag so
     * the server broadcasts its reply (chaddr stays the Apple II MAC, which
     * the AP would never deliver as a unicast dst). Zeroing the UDP checksum
     * is legal for IPv4 and cheaper than incremental fixup. */
    uint16_t udp = ipv4_udp_offset(frame, len);
    if (udp != 0 && rd_be16(frame + udp) == 68 && rd_be16(frame + udp + 2) == 67) {
        uint16_t bootp = (uint16_t)(udp + 8);
        if (len >= (uint16_t)(bootp + 12)) {                 /* flags at bootp+10..11 */
            if (!(frame[bootp + 10] & 0x80)) {
                frame[bootp + 10] |= 0x80;                   /* BOOTP flags |= 0x8000 */
                changed = true;
            }
            if (frame[udp + 6] | frame[udp + 7]) {
                frame[udp + 6] = 0;                          /* UDP checksum = 0 */
                frame[udp + 7] = 0;
                changed = true;
            }
        }
    }
    return changed;
}

bool wifi_bridge_fixup_ingress(uint8_t *frame, uint16_t len,
                               const uint8_t apple_mac[6], const uint8_t sta_mac[6])
{
    if (len < 14) return false;
    bool changed = false;

    /* 1. Unicast-to-us: destination MAC -> Apple II SHAR. Broadcast/multicast
     * (bit0 of the first octet) passes through unchanged. */
    if (!(frame[0] & 0x01) && memcmp(frame, sta_mac, 6) == 0 &&
        memcmp(frame, apple_mac, 6) != 0) {
        memcpy(frame, apple_mac, 6);
        changed = true;
    }

    /* 2. ARP: rewrite target-hardware-address when it names the STA MAC */
    if (rd_be16(frame + 12) == 0x0806 && len >= 42 &&
        memcmp(frame + 32, sta_mac, 6) == 0 &&
        memcmp(frame + 32, apple_mac, 6) != 0) {
        memcpy(frame + 32, apple_mac, 6);
        changed = true;
    }
    return changed;
}

/* =========================================================================
 * Ingress path (WiFi task -> ring -> main loop)
 * ========================================================================= */

/* WiFi driver RX callback. Runs in the WiFi task: keep it cheap -- copy at
 * most, no FPGA-link traffic here. Always forwards the frame to the ESP32's
 * own lwIP via esp_netif_receive() (which owns/frees `eb`). */
static esp_err_t bridge_rxcb(void *buffer, uint16_t len, void *eb)
{
    const uint8_t *f = (const uint8_t *)buffer;

    if (len >= 14 && len <= W5100_MAX_FRAME && w5100_macraw_active()) {
        bool mcast = (f[0] & 0x01) != 0;                    /* covers broadcast */
        bool tous  = (memcmp(f, s_sta_mac, 6) == 0);
        if (mcast || tous) {
            uint32_t head = __atomic_load_n(&s_rx_head, __ATOMIC_RELAXED);
            uint32_t tail = __atomic_load_n(&s_rx_tail, __ATOMIC_ACQUIRE);
            if (head - tail < BR_RX_SLOTS) {
                rx_slot_t *slot = &s_rx[head & BR_RX_MASK];
                memcpy(slot->buf, f, len);
                slot->len = len;
                __atomic_store_n(&s_rx_head, head + 1, __ATOMIC_RELEASE);
            } else {
                s_rx_drop_ring++;
            }
        }
    }

    /* Keep the ESP32's own IP stack alive (DHCP lease renewal, etc.) */
    if (s_netif)
        return esp_netif_receive(s_netif, buffer, len, eb);
    esp_wifi_internal_free_rx_buffer(eb);
    return ESP_OK;
}

void wifi_bridge_poll(void)
{
    uint32_t tail = __atomic_load_n(&s_rx_tail, __ATOMIC_RELAXED);
    uint32_t head = __atomic_load_n(&s_rx_head, __ATOMIC_ACQUIRE);

    while (tail != head) {
        rx_slot_t *slot = &s_rx[tail & BR_RX_MASK];

        uint8_t apple[6];
        bool have_apple = s_apple_valid ? (memcpy(apple, s_apple_mac, 6), true)
                                        : w5100_get_mac(apple);
        if (have_apple)
            wifi_bridge_fixup_ingress(slot->buf, slot->len, apple, s_sta_mac);

        w5100_macraw_rx(slot->buf, slot->len);

        tail++;
        __atomic_store_n(&s_rx_tail, tail, __ATOMIC_RELEASE);
        head = __atomic_load_n(&s_rx_head, __ATOMIC_ACQUIRE);
    }
}

/* =========================================================================
 * w5100.h bridge hooks (override the weak stubs in w5100.c)
 * ========================================================================= */

void w5100_bridge_tx(const uint8_t *frame, uint32_t len)
{
    if (!s_started || !s_link_up || len < 14 || len > W5100_MAX_FRAME)
        return;

    memcpy(s_tx_buf, frame, len);

    uint8_t apple[6];
    const uint8_t *inner = s_sta_mac;   /* unknown SHAR: ARP compare is a no-op */
    if (s_apple_valid)
        inner = s_apple_mac;
    else if (w5100_get_mac(apple))
        inner = apple;

    wifi_bridge_fixup_egress(s_tx_buf, (uint16_t)len, inner, s_sta_mac);

    int r = esp_wifi_internal_tx(WIFI_IF_STA, s_tx_buf, (uint16_t)len);
    if (r != 0) {
        if ((++s_tx_err & 0x3F) == 1)   /* rate-limited */
            ESP_LOGW(TAG, "raw tx failed (%d), %lu total", r, (unsigned long)s_tx_err);
    }
}

bool w5100_bridge_uplink_mac(uint8_t mac[6])
{
    if (!s_started) return false;
    memcpy(mac, s_sta_mac, 6);
    return true;
}

void w5100_bridge_set_uplink_mac(const uint8_t mac[6])
{
    /* WiFi STA cannot impersonate the Apple II's MAC on air; record SHAR as
     * the MAC-NAT inner address instead. */
    memcpy(s_apple_mac, mac, 6);
    s_apple_valid = (mac[0] | mac[1] | mac[2] | mac[3] | mac[4] | mac[5]) != 0;
    ESP_LOGI(TAG, "NAT inner MAC (SHAR) %02x:%02x:%02x:%02x:%02x:%02x",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}

void w5100_bridge_set_promiscuous(void)
{
    /* Not applicable: STA MAC NAT replaces the promiscuous fallback. */
    ESP_LOGW(TAG, "promiscuous mode not supported on the WiFi uplink");
}

/* =========================================================================
 * WiFi bring-up
 * ========================================================================= */

static void on_wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg; (void)base; (void)data;
    switch (id) {
    case WIFI_EVENT_STA_START:
        esp_wifi_connect();
        break;
    case WIFI_EVENT_STA_CONNECTED:
        s_link_up = true;
        /* Take over the STA RX path. Registered after esp-netif's default
         * handler (registration order), so this wins on every (re)connect;
         * bridge_rxcb forwards to esp_netif_receive so lwIP still runs. */
        esp_wifi_internal_reg_rxcb(WIFI_IF_STA, bridge_rxcb);
        ESP_LOGI(TAG, "associated with '%s'", s_ssid);
        break;
    case WIFI_EVENT_STA_DISCONNECTED:
        s_link_up = false;
        s_got_ip = false;
        s_ip = 0;
        esp_wifi_connect();   /* keep retrying */
        break;
    default:
        break;
    }
}

/* Apply the stored DHCP/static-IP choice to the netif (no-op until the
 * netif exists). Static config takes effect immediately; DHCP restarts the
 * client and the address arrives via IP_EVENT_STA_GOT_IP. */
static void apply_ip_config(void)
{
    if (!s_netif)
        return;

    bool zero_ip = !(s_cfg_ip[0] | s_cfg_ip[1] | s_cfg_ip[2] | s_cfg_ip[3]);
    if (s_use_static && !zero_ip) {
        esp_netif_ip_info_t info;
        memset(&info, 0, sizeof(info));
        info.ip.addr      = (uint32_t)s_cfg_ip[0] | ((uint32_t)s_cfg_ip[1] << 8) |
                            ((uint32_t)s_cfg_ip[2] << 16) | ((uint32_t)s_cfg_ip[3] << 24);
        info.netmask.addr = (uint32_t)s_cfg_mask[0] | ((uint32_t)s_cfg_mask[1] << 8) |
                            ((uint32_t)s_cfg_mask[2] << 16) | ((uint32_t)s_cfg_mask[3] << 24);
        info.gw.addr      = (uint32_t)s_cfg_gw[0] | ((uint32_t)s_cfg_gw[1] << 8) |
                            ((uint32_t)s_cfg_gw[2] << 16) | ((uint32_t)s_cfg_gw[3] << 24);
        esp_netif_dhcpc_stop(s_netif);
        esp_err_t err = esp_netif_set_ip_info(s_netif, &info);
        if (err == ESP_OK) {
            s_ip = info.ip.addr;
            s_static_applied = true;
            ESP_LOGI(TAG, "static ip %u.%u.%u.%u mask %u.%u.%u.%u gw %u.%u.%u.%u",
                     s_cfg_ip[0], s_cfg_ip[1], s_cfg_ip[2], s_cfg_ip[3],
                     s_cfg_mask[0], s_cfg_mask[1], s_cfg_mask[2], s_cfg_mask[3],
                     s_cfg_gw[0], s_cfg_gw[1], s_cfg_gw[2], s_cfg_gw[3]);
        } else {
            ESP_LOGE(TAG, "esp_netif_set_ip_info: %s", esp_err_to_name(err));
        }
    } else {
        s_static_applied = false;
        esp_netif_dhcpc_start(s_netif);  /* idempotent; INVALID_STATE if running */
    }
}

void wifi_bridge_config_ip(bool dhcp, const uint8_t ip[4],
                           const uint8_t mask[4], const uint8_t gw[4])
{
    s_use_static = !dhcp;
    if (ip)   memcpy(s_cfg_ip, ip, 4);     else memset(s_cfg_ip, 0, 4);
    if (mask) memcpy(s_cfg_mask, mask, 4); else memset(s_cfg_mask, 0, 4);
    if (gw)   memcpy(s_cfg_gw, gw, 4);     else memset(s_cfg_gw, 0, 4);
    apply_ip_config();
}

static void on_ip_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg; (void)base;
    if (id == IP_EVENT_STA_GOT_IP) {
        const ip_event_got_ip_t *e = (const ip_event_got_ip_t *)data;
        s_ip = e->ip_info.ip.addr;
        s_got_ip = true;
        ESP_LOGI(TAG, "ESP32 ip " IPSTR " (Apple II traffic is bridged at L2)",
                 IP2STR(&e->ip_info.ip));
    } else if (id == IP_EVENT_STA_LOST_IP) {
        s_got_ip = false;
        s_ip = 0;
    }
}

bool wifi_bridge_init(const char *ssid, const char *psk)
{
    if (s_started) return true;
    if (!ssid || !ssid[0]) {
        ESP_LOGW(TAG, "no SSID configured; bridge disabled");
        return false;
    }
    strncpy(s_ssid, ssid, sizeof(s_ssid) - 1);
    s_ssid[sizeof(s_ssid) - 1] = 0;

    /* esp_wifi needs NVS; tolerate it already being initialized (Arduino) */
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        nvs_flash_erase();
        err = nvs_flash_init();
    }
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
        ESP_LOGE(TAG, "nvs_flash_init: %s", esp_err_to_name(err));
        return false;
    }

    if (esp_netif_init() != ESP_OK) return false;
    err = esp_event_loop_create_default();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) return false;

    if (!s_netif)
        s_netif = esp_netif_create_default_wifi_sta();
    if (!s_netif) return false;

    apply_ip_config();   /* honor a static config set before init */

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    err = esp_wifi_init(&cfg);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_wifi_init: %s", esp_err_to_name(err));
        return false;
    }

    esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                        on_wifi_event, NULL, NULL);
    esp_event_handler_instance_register(IP_EVENT, ESP_EVENT_ANY_ID,
                                        on_ip_event, NULL, NULL);

    esp_wifi_set_storage(WIFI_STORAGE_RAM);   /* config from settings, not NVS */

    wifi_config_t wc;
    memset(&wc, 0, sizeof(wc));
    strncpy((char *)wc.sta.ssid, ssid, sizeof(wc.sta.ssid) - 1);
    if (psk)
        strncpy((char *)wc.sta.password, psk, sizeof(wc.sta.password) - 1);
    wc.sta.threshold.authmode = (psk && psk[0]) ? WIFI_AUTH_WPA2_PSK : WIFI_AUTH_OPEN;
    wc.sta.pmf_cfg.capable = true;
    wc.sta.pmf_cfg.required = false;

    if (esp_wifi_set_mode(WIFI_MODE_STA) != ESP_OK) return false;
    if (esp_wifi_set_config(WIFI_IF_STA, &wc) != ESP_OK) return false;

    err = esp_wifi_start();
    /* Disable modem power save: the default WIFI_PS_MIN_MODEM sleeps the
     * radio between DTIM beacons, which on UniFi-class APs turns sustained
     * INBOUND traffic (ping, TCP SYN, FTP) into near-total loss while
     * association/DHCP/outbound look perfect — live-debugged exactly so.
     * The bridge + FTP server need the radio always listening. */
    esp_wifi_set_ps(WIFI_PS_NONE);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_wifi_start: %s", esp_err_to_name(err));
        return false;
    }
    esp_wifi_get_mac(WIFI_IF_STA, s_sta_mac);
    s_started = true;

    ESP_LOGI(TAG, "STA started, mac %02x:%02x:%02x:%02x:%02x:%02x, ssid '%s'",
             s_sta_mac[0], s_sta_mac[1], s_sta_mac[2],
             s_sta_mac[3], s_sta_mac[4], s_sta_mac[5], s_ssid);
    return true;
}

/* ---- net status helpers (declared in wifi_bridge.h / net_status.h) ---- */

const char *net_ssid(void)   { return s_ssid; }
bool net_connected(void)     { return s_link_up && (s_got_ip || s_static_applied); }
uint32_t net_ip(void)        { return s_ip; }
