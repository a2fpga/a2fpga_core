/*
 * net_uplink.c -- w5100.h bridge hooks routed to the active uplink
 * (USB-Ethernet when its link is up, else WiFi). See net_uplink.h.
 */
#include "net_uplink.h"
#include "w5100.h"
#include "wifi_bridge.h"
#include "usbeth.h"
#include "osd_console.h"

#include "esp_log.h"

static const char *TAG = "uplink";
static bool s_usb_active;      /* the Apple II is currently bridged over USB */

static inline bool usb_now(void) { return usbeth_link_up(); }

void w5100_bridge_tx(const uint8_t *frame, uint32_t len)
{
    if (usb_now()) usbeth_tx(frame, len);
    else           wifi_bridge_tx(frame, len);
}

bool w5100_bridge_uplink_mac(uint8_t mac[6])
{
    if (usb_now()) return usbeth_mac(mac);
    return wifi_bridge_uplink_mac(mac);
}

void w5100_bridge_set_uplink_mac(const uint8_t mac[6])
{
    /* Both uplinks keep the Apple II SHAR as their NAT inner MAC so a
     * later switch needs no re-announcement from the W5100 core. */
    usbeth_set_apple_mac(mac);
    wifi_bridge_set_apple_mac(mac);
}

void w5100_bridge_set_promiscuous(void)
{
    ESP_LOGW(TAG, "promiscuous mode not used: both uplinks run MAC NAT");
}

void net_uplink_poll(void)
{
    bool usb = usb_now();
    if (usb != s_usb_active) {
        s_usb_active = usb;
        usbeth_set_bridging(usb);
        wifi_bridge_set_bridging(!usb);
        osd_log("UTHERNET UPLINK: %s", usb ? "USB ETHERNET" : (wifi_bridge_started() ? "WIFI" : "NONE"));
        ESP_LOGI(TAG, "Apple II uplink -> %s", usb ? "usb" : "wifi");
    }
    wifi_bridge_poll();
    usbeth_poll();
}

const char *net_uplink_name(void)
{
    if (usb_now()) return "USB ETHERNET";
    if (wifi_bridge_started()) return "WIFI";
    return "NONE";
}

bool net_uplink_any_ip(void)
{
    return usbeth_got_ip() || net_connected();
}
