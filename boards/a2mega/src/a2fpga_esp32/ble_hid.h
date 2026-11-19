/*
 * ble_hid — BLE HID host (HID over GATT, "HOGP") on the ESP32-S3's own
 * radio, so a Bluetooth remote / keyboard / gamepad can drive the menu
 * without taking a channel on the USB OTG host (hub + stick + Ethernet fill
 * all eight — see boards/a2mega/docs/BLE_HID_FEASIBILITY.md).
 *
 * Built on the raw esp-nimble host API shipped in the Arduino core (the IDF
 * esp_hidh component is compiled out of those libs). One bonded peer at a
 * time, kept in NVS ("blehid"/"peer"; the LTK/IRK live in NimBLE's own
 * "nimble_bond" store). Just Works pairing — no passkey, no text input.
 *
 * Life cycle:
 *   boot  -> peer known?  yes: RECONNECT (the controller initiates to that
 *            address at a 5 % scan duty until the device advertises)
 *                          no: IDLE
 *   PAIR  -> PAIR_SCAN (active scan 60 s, HID advertisers listed by RSSI)
 *         -> pick one (menu) or the strongest after a countdown
 *         -> CONNECTING -> SECURING (bond) -> DISCOVERING (HID service,
 *            Report Map, Report References, subscribe) -> CONNECTED
 *   drop  -> back to RECONNECT
 *
 * Output: a button word in the menu's A2PAD_* layout, OR-ed into
 * menu_tick() beside the FPGA pad and the USB host.
 */
#ifndef BLE_HID_H
#define BLE_HID_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    BLEH_OFF,          /* not started / stack failed                      */
    BLEH_IDLE,         /* up, no peer paired                               */
    BLEH_RECONNECT,    /* waiting for the paired device to advertise       */
    BLEH_PAIR_SCAN,    /* pairing: scanning for HID advertisers            */
    BLEH_CONNECTING,   /* link being established                          */
    BLEH_SECURING,     /* pairing/encryption in progress                   */
    BLEH_DISCOVERING,  /* GATT: HID service, report map, subscriptions     */
    BLEH_CONNECTED,    /* reports flowing                                  */
    BLEH_ERROR,        /* last attempt failed (see ble_hid_message)        */
} ble_hid_state_t;

/* Start the NimBLE host (production builds only). Safe to call once; logs
 * the internal-heap cost to the OSD console. */
void            ble_hid_start(void);
/* Call every ~20 ms from the menu task: pairing countdown + timeouts. */
void            ble_hid_poll(void);

bool            ble_hid_available(void);     /* stack up and synced */
ble_hid_state_t ble_hid_state(void);
const char     *ble_hid_state_str(void);     /* <= 12 chars, menu value column */
const char     *ble_hid_message(void);       /* last event, one line, "" if none */
bool            ble_hid_take_dirty(void);    /* something changed since last call */

bool            ble_hid_connected(void);
uint16_t        ble_hid_buttons(void);       /* A2PAD_* word, 0 when not connected */

/* the paired peer (NVS record) */
bool            ble_hid_peer_known(void);
const char     *ble_hid_peer_name(void);     /* "" when unknown */
void            ble_hid_peer_addr_str(char *out, int cap);
void            ble_hid_forget(void);        /* drop bond + record, disconnect */

/* pairing */
bool            ble_hid_pairing(void);       /* PAIR begun, not yet resolved */
int             ble_hid_pair_result(void);   /* 0 in progress / 1 paired / -1 failed, cleared by pair_begin */
void            ble_hid_pair_begin(void);
void            ble_hid_pair_cancel(void);
int             ble_hid_pair_auto_seconds(void);   /* -1 = no countdown running */
int             ble_hid_candidates(void);
bool            ble_hid_candidate(int i, char *name, int ncap, char *addr, int acap, int *rssi);
void            ble_hid_pair_select(int i);        /* -1 = strongest */

/* console: "ble [pair|cancel|forget|list|connect <n>]"; out() gets one line
 * at a time without a newline. */
void            ble_hid_console(int argc, const char *const *argv,
                                void (*out)(void *ctx, const char *line), void *ctx);

#ifdef __cplusplus
}
#endif
#endif
