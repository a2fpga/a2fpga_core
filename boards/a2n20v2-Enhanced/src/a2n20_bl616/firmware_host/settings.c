/*
 * settings.c — see settings.h. Blob lives in the last 4 KB flash sector.
 */
#include <stdio.h>
#include <string.h>

#include "bflb_flash.h"
#include "settings.h"

#define SETTINGS_SECTOR_BYTES 4096u

/* MUST MATCH hdl/slots/slots.hex (slot 0..7). */
const uint8_t settings_slot_hw_defaults[8] = { 0, 0, 3, 5, 2, 4, 6, 1 };

/* Version 1 blob layout (32-byte image names), kept for migration. */
typedef struct {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    uint8_t  boot_pref;
    uint8_t  dhcp_enable;
    uint8_t  slot_cards[8];
    char     disk_img[SETTINGS_NDRV][32];
    char     hdd_img[SETTINGS_NHDD][32];
    uint8_t  static_ip[4];
    uint8_t  static_mask[4];
    uint8_t  static_gw[4];
    uint8_t  eject_mask;
    uint8_t  reserved[13];
    uint32_t crc;
} a2_settings_v1_t;

static uint32_t v1_crc(const a2_settings_v1_t *c);
static bool try_load_v1(void);

static a2_settings_t s_cfg;
static bool          s_from_flash;
static uint32_t      s_flash_addr;   /* 0 until settings_init() */
static uint32_t      s_flash_size;

/* diagnostics */
static const char *s_load_why = "?";     /* OK/RD/MAG/SZ/VER/CRC */
static char        s_save_why[12] = "-"; /* OK / E<rc>@ER|WR|RB|VF */

/* CRC-32 (IEEE, reflected), bitwise — tiny and fast enough for 128 bytes. */
static uint32_t crc32_calc(const uint8_t *p, uint32_t n)
{
    uint32_t crc = 0xFFFFFFFFu;
    while (n--) {
        crc ^= *p++;
        for (int i = 0; i < 8; i++)
            crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
    return ~crc;
}

static uint32_t blob_crc(const a2_settings_t *c)
{
    return crc32_calc((const uint8_t *)c,
                      (uint32_t)((const uint8_t *)&c->crc - (const uint8_t *)c));
}

void settings_reset_defaults(void)
{
    memset(&s_cfg, 0, sizeof(s_cfg));
    s_cfg.magic       = SETTINGS_MAGIC;
    s_cfg.version     = SETTINGS_VERSION;
    s_cfg.size        = sizeof(s_cfg);
    s_cfg.boot_pref   = BOOT_PREF_AUTO;
    s_cfg.dhcp_enable = 1;
    memset(s_cfg.slot_cards, 0xFF, sizeof(s_cfg.slot_cards));  /* hw default */
}

void settings_init(void)
{
    s_flash_size = bflb_flash_get_size();
    if (s_flash_size < 0x100000u)        /* sanity: at least 1 MB */
        s_flash_size = 0x400000u;
    s_flash_addr = s_flash_size - SETTINGS_SECTOR_BYTES;

    a2_settings_t blob;
    settings_reset_defaults();
    s_from_flash = false;

    if (bflb_flash_read(s_flash_addr, (uint8_t *)&blob, sizeof(blob)) != 0) {
        s_load_why = "RD";
        return;
    }
    if (blob.magic != SETTINGS_MAGIC) { s_load_why = "MAG"; return; }
    if (blob.version == 1) {
        /* field-preserving upgrade from the 32-byte-name layout */
        if (try_load_v1()) {
            s_from_flash = true;
            s_load_why = "OK1";
        } else {
            s_load_why = "V1";
        }
        return;
    }
    if (blob.size != sizeof(blob))    { s_load_why = "SZ";  return; }
    if (blob.version != SETTINGS_VERSION) { s_load_why = "VER"; return; }
    if (blob_crc(&blob) != blob.crc)  { s_load_why = "CRC"; return; }

    s_cfg = blob;
    s_from_flash = true;
    s_load_why = "OK";
}

a2_settings_t *settings(void)
{
    return &s_cfg;
}

bool settings_save(void)
{
    int rc;
    if (!s_flash_addr)
        return false;
    s_cfg.magic   = SETTINGS_MAGIC;
    s_cfg.version = SETTINGS_VERSION;
    s_cfg.size    = sizeof(s_cfg);
    s_cfg.crc     = blob_crc(&s_cfg);

    rc = bflb_flash_erase(s_flash_addr, SETTINGS_SECTOR_BYTES);
    if (rc != 0) {
        snprintf(s_save_why, sizeof(s_save_why), "E%d@ER", rc);
        return false;
    }
    rc = bflb_flash_write(s_flash_addr, (uint8_t *)&s_cfg, sizeof(s_cfg));
    if (rc != 0) {
        snprintf(s_save_why, sizeof(s_save_why), "E%d@WR", rc);
        return false;
    }

    /* verify */
    a2_settings_t back;
    rc = bflb_flash_read(s_flash_addr, (uint8_t *)&back, sizeof(back));
    if (rc != 0) {
        snprintf(s_save_why, sizeof(s_save_why), "E%d@RB", rc);
        return false;
    }
    if (memcmp(&back, &s_cfg, sizeof(s_cfg)) != 0) {
        snprintf(s_save_why, sizeof(s_save_why), "VF");
        return false;
    }
    snprintf(s_save_why, sizeof(s_save_why), "OK");
    return true;
}

static uint32_t v1_crc(const a2_settings_v1_t *c)
{
    return crc32_calc((const uint8_t *)c,
                      (uint32_t)((const uint8_t *)&c->crc - (const uint8_t *)c));
}

static bool try_load_v1(void)
{
    a2_settings_v1_t v1;
    if (bflb_flash_read(s_flash_addr, (uint8_t *)&v1, sizeof(v1)) != 0)
        return false;
    if (v1.magic != SETTINGS_MAGIC || v1.version != 1 ||
        v1.size != sizeof(v1) || v1_crc(&v1) != v1.crc)
        return false;

    settings_reset_defaults();
    s_cfg.boot_pref   = v1.boot_pref;
    s_cfg.dhcp_enable = v1.dhcp_enable;
    memcpy(s_cfg.slot_cards, v1.slot_cards, sizeof(s_cfg.slot_cards));
    for (int i = 0; i < SETTINGS_NDRV; i++)
        snprintf(s_cfg.disk_img[i], SETTINGS_NAME_LEN, "%.31s", v1.disk_img[i]);
    for (int i = 0; i < SETTINGS_NHDD; i++)
        snprintf(s_cfg.hdd_img[i], SETTINGS_NAME_LEN, "%.31s", v1.hdd_img[i]);
    memcpy(s_cfg.static_ip,   v1.static_ip,   4);
    memcpy(s_cfg.static_mask, v1.static_mask, 4);
    memcpy(s_cfg.static_gw,   v1.static_gw,   4);
    s_cfg.eject_mask = v1.eject_mask;
    return true;
}

void settings_debug_line(char *out, int cap)
{
    snprintf(out, cap, "FLASH %luM @%05lX LD:%s SV:%s",
             (unsigned long)(s_flash_size >> 20),
             (unsigned long)s_flash_addr, s_load_why, s_save_why);
}

bool settings_loaded_from_flash(void)
{
    return s_from_flash;
}
