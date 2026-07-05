/*
 * wifi_bridge.h -- WiFi STA uplink for the W5100 MACRAW bridge (a2mega ESP32).
 *
 * Replaces the a2n20v2-Enhanced USB-Ethernet transport: MACRAW frames from the
 * emulated Uthernet II (w5100.c) are bridged onto the WLAN through the ESP32's
 * station interface using raw L2 TX (esp_wifi_internal_tx) and the WiFi driver
 * RX callback (esp_wifi_internal_reg_rxcb), with MAC NAT because an 802.11 STA
 * link only passes frames bearing the station's own MAC:
 *
 *   EGRESS (Apple II -> LAN), applied by wifi_bridge_fixup_egress():
 *     1. Ethernet source MAC (bytes 6-11)         -> ESP32 STA MAC (always)
 *     2. ARP (EtherType 0x0806): sender-hardware-address (bytes 22-27)
 *        rewritten when it equals the Apple II MAC
 *     3. DHCP client->server (IPv4 / UDP 68->67, unfragmented): BOOTP flags
 *        (offset BOOTP+10) |= 0x8000 (broadcast) and the UDP checksum is
 *        zeroed (legal for IPv4), so replies come back as broadcast even
 *        though chaddr stays the Apple II MAC
 *
 *   INGRESS (LAN -> Apple II), applied by wifi_bridge_fixup_ingress():
 *     1. Ethernet destination MAC (bytes 0-5)     -> Apple II SHAR when it
 *        equals the ESP32 STA MAC (broadcast/multicast pass unchanged)
 *     2. ARP: target-hardware-address (bytes 32-37) rewritten likewise
 *
 * The ESP32's own lwIP stays functional: the RX callback hands every frame on
 * to esp_netif_receive() after copying what the bridge needs, so the ESP32
 * keeps its own DHCP lease/IP independently of the Apple II's traffic.
 *
 * Implements the w5100.h bridge hooks (w5100_bridge_tx, w5100_bridge_uplink_mac,
 * w5100_bridge_set_uplink_mac, w5100_bridge_set_promiscuous).
 */
#pragma once

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Bring up WiFi STA (WPA2-PSK) and the bridge. Call once, after NVS-capable
 * startup (Arduino setup() is fine) and after w5100_init(). Returns false if
 * the WiFi driver could not be started (bad state / out of memory) -- a wrong
 * password only shows up later as net_connected() == false. */
bool wifi_bridge_init(const char *ssid, const char *psk);

/* Drain queued ingress frames into w5100_macraw_rx(). Call from the same main
 * loop (same task) as w5100_poll(); ~1 kHz cadence recommended. */
void wifi_bridge_poll(void);

/* ---- net status helpers (also declared in net_status.h) ---- */
const char *net_ssid(void);      /* configured SSID ("" before init) */
bool        net_connected(void); /* associated AND got a DHCP lease */
uint32_t    net_ip(void);        /* ESP32's own IPv4, network byte order; 0 if none */

/* ---- pure frame-fixup helpers (unit-testable, no ESP dependencies) ----
 * Both rewrite in place and return true if anything changed. `len` is the
 * full Ethernet frame length including the 14-byte header. */
bool wifi_bridge_fixup_egress(uint8_t *frame, uint16_t len,
                              const uint8_t apple_mac[6], const uint8_t sta_mac[6]);
bool wifi_bridge_fixup_ingress(uint8_t *frame, uint16_t len,
                               const uint8_t apple_mac[6], const uint8_t sta_mac[6]);

#ifdef __cplusplus
}
#endif
