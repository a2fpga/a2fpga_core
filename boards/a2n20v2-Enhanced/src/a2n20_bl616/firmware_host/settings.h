/*
 * settings — persistent board preferences for the a2n20v2-Enhanced host build.
 *
 * Stored as a versioned, CRC-protected blob in the LAST 4 KB sector of the
 * BL616's SPI flash (located with bflb_flash_get_size(), so it works on any
 * flash size and never collides with the firmware at 0x40000). A bad/missing
 * blob silently falls back to defaults; a failed write leaves the RAM copy
 * live for the session. Settings are read via settings(), mutated in place,
 * and persisted with settings_save() (the menu saves on change).
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

#define SETTINGS_MAGIC    0x41324650u   /* 'A2FP' */
#define SETTINGS_VERSION  2

/* boot_pref */
enum {
    BOOT_PREF_AUTO = 0,   /* USB stick if present, else SD card */
    BOOT_PREF_USB  = 1,   /* USB stick only */
    BOOT_PREF_SD   = 2,   /* SD card only */
};

#define SETTINGS_NDRV 2
#define SETTINGS_NHDD 2
#define SETTINGS_NAME_LEN 64   /* room for subdirectory paths */

typedef struct {
    uint32_t magic;
    uint16_t version;
    uint16_t size;                       /* sizeof(a2_settings_t) at save time */

    /* Storage / boot */
    uint8_t  boot_pref;                  /* BOOT_PREF_* */

    /* Network */
    uint8_t  dhcp_enable;                /* 1 = run DHCP on USB-Ethernet */

    /* Apple II slot map: card id per slot, 0xFF = keep the hardware default
     * (slots.hex). Applied at boot before the Apple II reset release, and on
     * demand from the menu (reconfig strobe). */
    uint8_t  slot_cards[8];

    /* Disk image overrides: tried before the built-in candidate lists.
     * Empty string = no override. FatFS paths without the "0:/" prefix;
     * may include subdirectories ("games/choplifter.dsk"). */
    char     disk_img[SETTINGS_NDRV][SETTINGS_NAME_LEN];
    char     hdd_img[SETTINGS_NHDD][SETTINGS_NAME_LEN];

    /* Static network config, used when dhcp_enable == 0. All-zero ip means
     * "not configured" (old settings blobs load as zeros here — compatible). */
    uint8_t  static_ip[4];
    uint8_t  static_mask[4];
    uint8_t  static_gw[4];

    /* Eject mask: bit set = leave that volume unmounted. Bits 0-1 = floppy
     * D1/D2, bits 4-5 = HDD unit 1/2. (Old blobs load as 0 = all mounted.) */
    uint8_t  eject_mask;

    uint8_t  reserved[13];               /* future fields (shrink as used) */

    uint32_t crc;                        /* CRC-32 of everything above */
} a2_settings_t;

/* Hardware default slot map (card id per slot). MUST MATCH hdl/slots/
 * slots.hex — the FPGA's power-on slot configuration. */
extern const uint8_t settings_slot_hw_defaults[8];

/* Load from flash (or defaults). Call once early in main. */
void settings_init(void);

/* The live settings. Mutate then call settings_save(). */
a2_settings_t *settings(void);

/* Persist to flash. Returns true on success (RAM copy stays live either way). */
bool settings_save(void);

/* Reset the RAM copy to defaults (does not save). */
void settings_reset_defaults(void);

/* True if the last load found a valid blob (vs falling back to defaults). */
bool settings_loaded_from_flash(void);

/* One-line diagnostic: flash size/addr, load result, last save result.
 * e.g. "FLASH 4MB @3FF000 LD:OK SV:OK" or "... LD:CRC SV:E-12@ER". */
void settings_debug_line(char *out, int cap);

#endif
