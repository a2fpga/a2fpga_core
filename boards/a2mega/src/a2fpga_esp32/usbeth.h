/*
 * usbeth -- USB-Ethernet adapter (CDC-ECM or CDC-NCM) hosted on USB1 as a
 * wired uplink for the Uthernet II (W5100 MACRAW) bridge and for the ESP32's
 * own IP stack (telnet, FTP, bitstream streaming).
 *
 * Why generic CDC and not vendor drivers: the a2n20v2-Enhanced BL616 bridge
 * ended up tied to two Realtek/ASIX vendor drivers because CherryUSB's
 * CDC-ECM host path never completed a bulk-IN. On the ESP32 the IDF usb_host
 * bulk path is proven (mass storage runs on it), so the standard class
 * drivers are the compatibility play: any adapter whose configuration 1 is
 * ECM or NCM works without knowing the chip. The IDF host library only
 * enumerates configuration 1 (the enum-filter callback is compiled out of
 * the Arduino libs); dual-configuration Realtek parts that put ECM on
 * configuration 2 are reached by usbeth_attach_alt(), which switches the
 * device itself and hands the library a stand-in descriptor -- see usbeth.c.
 *
 * Channel budget: the ESP32-S3 has eight host channels, one per pipe for
 * the life of a device (EP0 included). Hub 2 + USB stick 3 leave three: EP0
 * and the two bulk pipes. The notification pipe is claimed only when a
 * channel is left; a HID dongle (3) cannot share the dock with stick +
 * Ethernet.
 *
 * Frame path (mirrors wifi_bridge.c so w5100.c sees the same contract):
 *   - Apple II -> wire: w5100 SEND -> net_uplink -> usbeth_tx(): egress MAC
 *     NAT (Apple II SHAR -> adapter MAC) -> bulk OUT. The NAT is kept even
 *     though a wired adapter could run promiscuous: it works on every
 *     adapter regardless of filter support and keeps the two uplinks
 *     interchangeable.
 *   - wire -> Apple II: bulk IN completes in the usb_host client task, which
 *     copies broadcast/multicast and unicast-to-adapter frames into an SPSC
 *     ring; usbeth_poll() (main loop, same task as w5100_poll) applies the
 *     ingress NAT and hands them to w5100_macraw_rx().
 *   - Every received frame also goes to the ESP32's own lwIP through an
 *     esp_netif attached to this driver (route priority above WiFi STA, so
 *     the ESP32 prefers the wire when both links have an address).
 *
 * Link state comes from the NETWORK_CONNECTION notification on the control
 * interface's interrupt endpoint; adapters that never send one are assumed
 * up USBETH_LINK_ASSUME_MS after attach.
 *
 * Full Speed only (ESP32-S3 OTG): adapters fall back to 12 Mbit/s with
 * 64-byte bulk packets. Plenty for a 1 MHz Apple II.
 */
#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- called by usbhost.cpp (worker task) ----
 * Claim the function whose control interface is `ctrl_intf` in the active
 * configuration descriptor `cfg` (raw bytes, `cfg_len` = wTotalLength) and
 * start it. `client`/`dev` are the usb_host handles (void* to keep this
 * header C-clean). One adapter at a time; a second attach is refused. */
bool usbeth_attach(void *client, void *dev, const uint8_t *cfg, size_t cfg_len,
                   uint8_t ctrl_intf, uint16_t vid, uint16_t pid);
/* The active configuration has no CDC Ethernet function but the device has
 * `num_configs` configurations: look for one in the others and switch the
 * device to it (Realtek RTL8152/RTL8153: configuration 2 is CDC-ECM).
 * `active` MUST be the pointer usb_host_get_active_config_descriptor()
 * returned (the library's own buffer, rewritten in place; see usbeth.c).
 * Call only when nothing else on the device was claimed. Returns true when
 * the adapter is running. */
bool usbeth_attach_alt(void *client, void *dev, const uint8_t *active, size_t active_len,
                       uint8_t num_configs, uint16_t vid, uint16_t pid);
/* Device gone (or being dropped): release interfaces, free transfers, take
 * the netif down. Safe to call for a device that was never attached. */
void usbeth_detach(void *dev);

/* ---- main loop ----
 * Drain received frames into w5100_macraw_rx(), run link timers, log
 * state changes. Same task as w5100_poll(). */
void usbeth_poll(void);

/* ---- uplink interface used by net_uplink.c ---- */
bool usbeth_present(void);            /* an adapter is attached and configured */
bool usbeth_link_up(void);            /* ... and reports carrier */
bool usbeth_got_ip(void);             /* the ESP32 has an address on the wire */
uint32_t usbeth_ip(void);             /* ESP32 IPv4 on the wire (lwIP u32 order), 0 if none */
bool usbeth_mac(uint8_t mac[6]);      /* adapter MAC (= NAT outer MAC); false if absent */
void usbeth_set_apple_mac(const uint8_t mac[6]);   /* Apple II SHAR (NAT inner MAC) */
/* Whether received frames are copied towards the Apple II. The dispatcher
 * turns this off while WiFi is the active uplink so broadcasts are not
 * delivered twice. Default on. */
void usbeth_set_bridging(bool on);
/* Send one Ethernet frame on behalf of the Apple II (egress NAT applied). */
void usbeth_tx(const uint8_t *frame, uint32_t len);

/* One-line status for the CLI / OSD, e.g.
 * "USB ETH: 0BDA:8152 ECM mac .. link UP ip 192.168.1.20 rx 120 tx 44" */
void usbeth_status(char *buf, size_t cap);

/* Link assumed up when no NETWORK_CONNECTION notification arrives in time */
#define USBETH_LINK_ASSUME_MS 3000

#ifdef __cplusplus
}
#endif
