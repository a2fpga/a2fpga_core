/*
 * net_uplink -- picks the uplink for the Uthernet II (W5100 MACRAW) bridge.
 *
 * Two uplinks exist: the WiFi STA bridge (wifi_bridge.c) and a USB-Ethernet
 * adapter on USB1 (usbeth.c). Both implement the same MAC-NAT scheme, so
 * the W5100 core (w5100.c) talks to the four w5100_bridge_* hooks and this
 * module routes them: the wire wins whenever an adapter reports carrier,
 * WiFi otherwise. Only the active uplink feeds received frames to the
 * Apple II (the other is told to stop bridging), so a broadcast never
 * arrives twice. Switching uplinks changes the NAT outer MAC; LAN peers
 * re-learn it on their next ARP, the Apple II keeps its IP.
 */
#pragma once

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Service both uplinks' ingress rings and the uplink choice. Call from the
 * main loop right after w5100_poll() (same task). */
void net_uplink_poll(void);

/* "USB ETHERNET", "WIFI" or "NONE" -- the uplink the Apple II is on now. */
const char *net_uplink_name(void);
/* true if either uplink has an IP for the ESP32 (servers are reachable). */
bool net_uplink_any_ip(void);

#ifdef __cplusplus
}
#endif
