/*
 * fwupdate.c — MCU self-update via ESP-IDF OTA (see fwupdate.h).
 */
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include <sys/stat.h>

#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_partition.h"
#include "esp_system.h"
#include "esp_timer.h"

#include "fwupdate.h"
#include "osd_console.h"
#include "disk.h"

static const char *TAG = "fwupdate";

#define FWU_ROOT     "/sdcard"
#define FWU_MIN_SIZE (256u * 1024u)
#define FWU_CHUNK    4096u
#define ESP_IMAGE_MAGIC 0xE9
#define ESP_CHIP_ID_S3  0x0009

static volatile fwu_state_t s_state = FWU_IDLE;
static char     s_path[160];
static char     s_msg[41];
static uint32_t s_size;
static bool     s_dirty = true;
static int64_t  s_restart_at_us;
static const esp_partition_t *s_target;

static void set_msg(const char *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    vsnprintf(s_msg, sizeof(s_msg), fmt, ap);
    va_end(ap);
    s_dirty = true;
}
static void fail(const char *why)
{
    s_state = FWU_ERROR;
    set_msg("%s", why);
    osd_log("MCU UPDATE: %s", why);
    ESP_LOGW(TAG, "%s", why);
}

bool fwupdate_request(const char *path)
{
    if (s_state == FWU_CHECKING || s_state == FWU_INSTALL_REQ || s_state == FWU_INSTALLING)
        return false;
    if (!path || !*path) return false;
    strncpy(s_path, path, sizeof(s_path) - 1); s_path[sizeof(s_path) - 1] = '\0';
    s_state = FWU_CHECKING;
    set_msg("CHECKING %s", s_path);
    return true;
}
void fwupdate_commit(void)
{
    if (s_state == FWU_READY) { s_state = FWU_INSTALL_REQ; set_msg("INSTALLING..."); }
}
void fwupdate_cancel(void)
{
    if (s_state == FWU_READY || s_state == FWU_ERROR) { s_state = FWU_IDLE; set_msg(""); }
}
fwu_state_t fwupdate_state(void) { return s_state; }
const char *fwupdate_message(void) { return s_msg; }
bool fwupdate_dirty(void) { bool d = s_dirty; s_dirty = false; return d; }
const char *fwupdate_running_slot(void)
{
    const esp_partition_t *r = esp_ota_get_running_partition();
    return r ? r->label : "?";
}

static const char *base_name(const char *p)
{
    const char *b = strrchr(p, '/');
    return b ? b + 1 : p;
}

static void do_check(void)
{
    char full[200];
    snprintf(full, sizeof(full), "%s/%s", FWU_ROOT, s_path);
    struct stat st;
    if (stat(full, &st) != 0) { fail("FILE NOT FOUND"); return; }
    s_size = (uint32_t)st.st_size;
    s_target = esp_ota_get_next_update_partition(NULL);
    if (!s_target) { fail("NO OTA PARTITION (REFLASH WITH OTA SCHEME)"); return; }
    if (s_size < FWU_MIN_SIZE) { fail("FILE TOO SMALL"); return; }
    if (s_size > s_target->size) { fail("FILE LARGER THAN OTA SLOT"); return; }
    FILE *f = fopen(full, "rb");
    if (!f) { fail("CANNOT OPEN FILE"); return; }
    uint8_t hdr[24];
    size_t n = fread(hdr, 1, sizeof(hdr), f);
    fclose(f);
    if (n != sizeof(hdr) || hdr[0] != ESP_IMAGE_MAGIC) { fail("NOT AN ESP32 IMAGE"); return; }
    uint16_t chip = (uint16_t)hdr[12] | ((uint16_t)hdr[13] << 8);
    if (chip != ESP_CHIP_ID_S3) { fail("IMAGE IS NOT FOR ESP32-S3"); return; }
    s_state = FWU_READY;
    set_msg("%.20s %uK -> %s", base_name(s_path), (unsigned)(s_size / 1024), s_target->label);
}

static void do_install(void)
{
    s_state = FWU_INSTALLING;
    char full[200];
    snprintf(full, sizeof(full), "%s/%s", FWU_ROOT, s_path);
    FILE *f = fopen(full, "rb");
    if (!f) { fail("CANNOT OPEN FILE"); return; }
    osd_log("MCU UPDATE: WRITING %s TO %s", base_name(s_path), s_target->label);
    esp_ota_handle_t h = 0;
    esp_err_t e = esp_ota_begin(s_target, s_size, &h);
    if (e != ESP_OK) { fclose(f); fail("OTA BEGIN FAILED"); return; }
    static uint8_t buf[FWU_CHUNK];
    uint32_t done = 0; int last_pct = -1;
    for (;;) {
        size_t n = fread(buf, 1, sizeof(buf), f);
        if (n == 0) break;
        e = esp_ota_write(h, buf, n);
        if (e != ESP_OK) { fclose(f); esp_ota_abort(h); fail("OTA WRITE FAILED"); return; }
        done += n;
        int pct = (int)((uint64_t)done * 100 / s_size);
        if (pct / 10 != last_pct / 10) { last_pct = pct; set_msg("INSTALLING %d%%", pct); osd_log("MCU UPDATE: %d%%", pct); }
    }
    fclose(f);
    if (done != s_size) { esp_ota_abort(h); fail("SHORT READ"); return; }
    e = esp_ota_end(h);                           /* validates the image */
    if (e != ESP_OK) { fail(e == ESP_ERR_OTA_VALIDATE_FAILED ? "IMAGE VALIDATION FAILED" : "OTA END FAILED"); return; }
    e = esp_ota_set_boot_partition(s_target);
    if (e != ESP_OK) { fail("SET BOOT PARTITION FAILED"); return; }
    s_state = FWU_DONE;
    set_msg("INSTALLED - RESTARTING");
    osd_log("MCU UPDATE: INSTALLED IN %s - RESTARTING", s_target->label);
    s_restart_at_us = esp_timer_get_time() + 2000000;
}

void fwupdate_poll(void)
{
    switch (s_state) {
    case FWU_CHECKING:    do_check();   break;
    case FWU_INSTALL_REQ: do_install(); break;
    case FWU_DONE:
        if (s_restart_at_us && esp_timer_get_time() >= s_restart_at_us) {
            s_restart_at_us = 0;
            disk_release_storage();   /* close images, detach the stick's FAT first */
            esp_restart();
        }
        break;
    default: break;
    }
}
