/*
 * net_status — read-only WiFi status accessors for the menu (declarations
 * only; the integrator implements these in the WiFi bring-up module).
 *
 * SSID/password provisioning is OUT of menu scope: it comes from
 * /sdcard/A2FPGA/wifi.txt or the serial CLI. The menu only displays status.
 */
#ifndef _NET_STATUS_H
#define _NET_STATUS_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Configured SSID ("" or NULL if none provisioned). */
const char *net_ssid(void);

/* True while the WiFi STA link is up. */
bool net_connected(void);

/* Current IPv4 address, first octet in the LOW byte (lwIP native u32_t
 * order, i.e. octets are ip&0xFF . ip>>8 . ip>>16 . ip>>24). 0 = none. */
uint32_t net_ip(void);

#ifdef __cplusplus
}
#endif

#endif
