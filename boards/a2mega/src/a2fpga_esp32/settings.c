/*
 * settings.c — see settings.h. Blob lives in NVS ("a2fpga"/"settings").
 */
#include <stdio.h>
#include <string.h>

#include "nvs_flash.h"
#include "nvs.h"
#include "esp_log.h"

#include "settings.h"

#define SETTINGS_NVS_NAMESPACE "a2fpga"
#define SETTINGS_NVS_KEY       "settings"

static const char *TAG = "settings";

/* MUST MATCH hdl/slots/slots.hex (slot 0..7). */
const uint8_t settings_slot_hw_defaults[8] = { 0, 0, 3, 5, 2, 4, 6, 1 };

static a2_settings_t s_cfg;
static bool          s_from_nvs;
static bool          s_nvs_ready;     /* nvs_flash_init succeeded */

/* diagnostics */
static const char *s_load_why = "?";      /* OK/NVS/RD/SZ/MAG/VER/CRC */
static char        s_save_why[16] = "-";  /* OK / E<err>@OP|SET|COM */

/* CRC-32 (IEEE, reflected), bitwise — tiny and fast enough for the blob. */
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
    settings_reset_defaults();
    s_from_nvs = false;

    /* Bring up the NVS partition (idempotent: returns ESP_OK if another
     * component already initialized it). A partition left over from an older
     * IDF layout or with no free pages must be erased once and re-inited. */
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_LOGW(TAG, "nvs_flash_init: %s - erasing NVS", esp_err_to_name(err));
        nvs_flash_erase();
        err = nvs_flash_init();
    }
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nvs_flash_init failed: %s", esp_err_to_name(err));
        s_load_why = "NVS";
        return;
    }
    s_nvs_ready = true;

    nvs_handle_t h;
    err = nvs_open(SETTINGS_NVS_NAMESPACE, NVS_READONLY, &h);
    if (err != ESP_OK) {
        /* ESP_ERR_NVS_NOT_FOUND on first boot: no namespace yet */
        s_load_why = "RD";
        return;
    }

    a2_settings_t blob;
    size_t len = 0;
    err = nvs_get_blob(h, SETTINGS_NVS_KEY, NULL, &len);
    if (err != ESP_OK || len != sizeof(blob)) {
        nvs_close(h);
        s_load_why = (err != ESP_OK) ? "RD" : "SZ";
        return;
    }
    err = nvs_get_blob(h, SETTINGS_NVS_KEY, &blob, &len);
    nvs_close(h);
    if (err != ESP_OK) { s_load_why = "RD"; return; }

    if (blob.magic != SETTINGS_MAGIC)     { s_load_why = "MAG"; return; }
    if (blob.size != sizeof(blob))        { s_load_why = "SZ";  return; }
    if (blob.version != SETTINGS_VERSION) { s_load_why = "VER"; return; }
    if (blob_crc(&blob) != blob.crc)      { s_load_why = "CRC"; return; }

    s_cfg = blob;
    s_from_nvs = true;
    s_load_why = "OK";
    ESP_LOGI(TAG, "settings loaded from NVS (v%u, %u bytes)",
             (unsigned)s_cfg.version, (unsigned)s_cfg.size);
}

a2_settings_t *settings(void)
{
    return &s_cfg;
}

bool settings_save(void)
{
    if (!s_nvs_ready) {
        snprintf(s_save_why, sizeof(s_save_why), "NVS");
        return false;
    }
    s_cfg.magic   = SETTINGS_MAGIC;
    s_cfg.version = SETTINGS_VERSION;
    s_cfg.size    = sizeof(s_cfg);
    s_cfg.crc     = blob_crc(&s_cfg);

    nvs_handle_t h;
    esp_err_t err = nvs_open(SETTINGS_NVS_NAMESPACE, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        snprintf(s_save_why, sizeof(s_save_why), "E%d@OP", (int)err);
        ESP_LOGE(TAG, "nvs_open failed: %s", esp_err_to_name(err));
        return false;
    }
    err = nvs_set_blob(h, SETTINGS_NVS_KEY, &s_cfg, sizeof(s_cfg));
    if (err != ESP_OK) {
        nvs_close(h);
        snprintf(s_save_why, sizeof(s_save_why), "E%d@SET", (int)err);
        ESP_LOGE(TAG, "nvs_set_blob failed: %s", esp_err_to_name(err));
        return false;
    }
    err = nvs_commit(h);
    nvs_close(h);
    if (err != ESP_OK) {
        snprintf(s_save_why, sizeof(s_save_why), "E%d@COM", (int)err);
        ESP_LOGE(TAG, "nvs_commit failed: %s", esp_err_to_name(err));
        return false;
    }
    snprintf(s_save_why, sizeof(s_save_why), "OK");
    return true;
}

void settings_debug_line(char *out, int cap)
{
    snprintf(out, cap, "NVS %s/%s LD:%s SV:%s",
             SETTINGS_NVS_NAMESPACE, SETTINGS_NVS_KEY, s_load_why, s_save_why);
}

bool settings_loaded_from_flash(void)
{
    return s_from_nvs;
}
