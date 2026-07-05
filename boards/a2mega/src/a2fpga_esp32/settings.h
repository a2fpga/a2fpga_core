/*
 * settings — persistent board preferences for the a2mega ESP32 build.
 *
 * Same versioned, CRC-protected blob as the a2n20v2-Enhanced BL616 firmware,
 * stored in ESP32 NVS (namespace "a2fpga", key "settings") instead of a raw
 * flash sector. A bad/missing blob silently falls back to defaults; a failed
 * write leaves the RAM copy live for the session. Settings are read via
 * settings(), mutated in place, and persisted with settings_save() (the menu
 * saves on change).
 *
 * Growth policy: change the struct freely and bump SETTINGS_VERSION — the
 * loader treats any blob whose magic/version/size/CRC do not match exactly
 * as invalid and falls back to defaults (no migration; settings are cheap
 * to re-enter from the menu).
 */
#ifndef _SETTINGS_H
#define _SETTINGS_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SETTINGS_MAGIC    0x41324650u   /* 'A2FP' */
#define SETTINGS_VERSION  4             /* v4: +wifi_ssid/wifi_psk (ESP32) */

/* boot_pref — retained for blob/menu compatibility with the BL616 build.
 * The a2mega has SD-only storage, so the field is currently ignored. */
enum {
    BOOT_PREF_AUTO = 0,   /* USB stick if present, else SD card */
    BOOT_PREF_USB  = 1,   /* USB stick only */
    BOOT_PREF_SD   = 2,   /* SD card only */
};

#define SETTINGS_NDRV 2
#define SETTINGS_NHDD 2
#define SETTINGS_NAME_LEN 128  /* full LFN paths incl. subdirectories */

typedef struct {
    uint32_t magic;
    uint16_t version;
    uint16_t size;                       /* sizeof(a2_settings_t) at save time */

    /* Storage / boot (ignored on a2mega: SD is the only backend) */
    uint8_t  boot_pref;                  /* BOOT_PREF_* */

    /* Network */
    uint8_t  dhcp_enable;                /* 1 = run DHCP on the WiFi bridge */

    /* Apple II slot map: card id per slot, 0xFF = keep the hardware default
     * (slots.hex). Applied at boot before the Apple II reset release, and on
     * demand from the menu (reconfig strobe). */
    uint8_t  slot_cards[8];

    /* Disk image overrides: tried before the built-in candidate lists.
     * Empty string = no override. Paths relative to the SD card root (no
     * "/sdcard/" prefix); may include subdirectories ("games/chop.dsk"). */
    char     disk_img[SETTINGS_NDRV][SETTINGS_NAME_LEN];
    char     hdd_img[SETTINGS_NHDD][SETTINGS_NAME_LEN];

    /* Static network config, used when dhcp_enable == 0. All-zero ip means
     * "not configured". */
    uint8_t  static_ip[4];
    uint8_t  static_mask[4];
    uint8_t  static_gw[4];

    /* Eject mask: bit set = leave that volume unmounted. Bits 0-1 = floppy
     * D1/D2, bits 4-5 = HDD unit 1/2. */
    uint8_t  eject_mask;

    /* WiFi STA credentials (new in v4, ESP32 only). NUL-terminated. */
    char     wifi_ssid[33];              /* max 32-char SSID + NUL */
    char     wifi_psk[65];               /* max 64-char WPA passphrase + NUL */

    uint8_t  reserved[15];               /* future fields (shrink as used) */

    uint32_t crc;                        /* CRC-32 of everything above */
} a2_settings_t;

/* Hardware default slot map (card id per slot). MUST MATCH hdl/slots/
 * slots.hex — the FPGA's power-on slot configuration. */
extern const uint8_t settings_slot_hw_defaults[8];

/* Load from NVS (or defaults). Initializes nvs_flash if needed. Call once
 * early in setup, before disk_init()/menu_init(). */
void settings_init(void);

/* The live settings. Mutate then call settings_save(). */
a2_settings_t *settings(void);

/* Persist to NVS. Returns true on success (RAM copy stays live either way). */
bool settings_save(void);

/* Reset the RAM copy to defaults (does not save). */
void settings_reset_defaults(void);

/* True if the last load found a valid blob (vs falling back to defaults).
 * (Name kept from the BL616 build for menu compatibility; "flash" = NVS.) */
bool settings_loaded_from_flash(void);

/* One-line diagnostic: backing store, load result, last save result.
 * e.g. "NVS A2FPGA/SETTINGS LD:OK SV:OK" or "... LD:CRC SV:E4363@SET". */
void settings_debug_line(char *out, int cap);

#ifdef __cplusplus
}
#endif

#endif
