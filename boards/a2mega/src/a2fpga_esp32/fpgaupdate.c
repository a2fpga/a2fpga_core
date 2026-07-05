/*
 * fpgaupdate.c — FPGA bitstream self-update from the SD card.
 *
 * Writes a Gowin binary bitstream (the a2mega build emits binary FORMAT at
 * impl/pnr/a2mega.fs) into the GW5AT-60's external SPI config flash over
 * bit-banged JTAG (fpga_jtag.c). There is no staging step: the running
 * bitstream must be killed (SRAM erase) before the flash is reachable, so
 * the screen and Apple II are down for the whole write. The menu paints a
 * full-screen warning first.
 *
 * Safety properties (ported from the a2n20v2-Enhanced BL616 updater):
 *  - CHECK phase validates the file BEFORE anything is touched: Gowin A5C3
 *    sync word near the start, embedded IDCODE == GW5AT-60 (0x0001481B),
 *    and a live JTAG IDCODE probe of the FPGA itself.
 *  - Every page is read back and compared immediately after programming,
 *    with one retry (a persistent mismatch aborts).
 *  - On success: JTAG RELOAD boots the new bitstream, then the ESP32
 *    restarts itself for a clean bring-up.
 *  - An interrupted/failed write leaves the FPGA unconfigured but the ESP32
 *    fully alive; recovery is openFPGALoader over the USB-C JTAG bridge.
 */
#include <stdint.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_system.h"
#include "esp_log.h"

#include "osd_console.h"
#include "fpga_jtag.h"
#include "fpgaupdate.h"

static const char *TAG = "fpgaupd";

#define FPU_MIN_SIZE   (512u * 1024u)
#define FPU_MAX_SIZE   (8u * 1024u * 1024u)
#define FPU_PAGE       256u
#define FPU_BLOCK      65536u
#define FPU_HDR_SCAN   4096u   /* window searched for sync word + IDCODE */

static volatile fpu_state_t s_state = FPU_IDLE;
static char     s_path[160];
static char     s_msg[41];
static uint32_t s_size;
static bool     s_dirty = true;
static uint8_t  s_page[FPU_PAGE];
static uint8_t  s_back[FPU_PAGE];

static void set_msg(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(s_msg, sizeof(s_msg), fmt, ap);
    va_end(ap);
    s_dirty = true;
}

static void fail(const char *why)
{
    s_state = FPU_ERROR;
    set_msg("%s", why);
    osd_log("FPGA: %s", why);
    ESP_LOGE(TAG, "%s", why);
}

/* ---- SPI flash primitives over fpga_jtag_spi_xfer ------------------------ */
static void flash_write_enable(void)
{
    fpga_jtag_spi_xfer(0x06, NULL, NULL, 0);
}

static bool flash_wait_busy(uint32_t loops)
{
    while (loops--) {
        uint8_t rx = 0xFF;
        fpga_jtag_spi_xfer(0x05, NULL, &rx, 1);
        if (!(rx & 0x01))
            return true;
    }
    return false;
}

static bool flash_erase_block(uint32_t addr)
{
    flash_write_enable();
    uint8_t tx[3] = { (uint8_t)(addr >> 16), (uint8_t)(addr >> 8),
                      (uint8_t)addr };
    fpga_jtag_spi_xfer(0xD8, tx, NULL, 3);
    return flash_wait_busy(20000);       /* block erase: up to ~2 s */
}

static bool flash_program_page(uint32_t addr, const uint8_t *data, uint32_t n)
{
    uint8_t tx[3 + FPU_PAGE];
    flash_write_enable();
    tx[0] = (uint8_t)(addr >> 16);
    tx[1] = (uint8_t)(addr >> 8);
    tx[2] = (uint8_t)addr;
    memcpy(tx + 3, data, n);
    fpga_jtag_spi_xfer(0x02, tx, NULL, 3 + n);
    return flash_wait_busy(4000);        /* page program: ~0.7 ms typ */
}

/* ---- public API ---------------------------------------------------------- */
bool fpgaupdate_request(const char *path)
{
    if (s_state == FPU_CHECKING || s_state == FPU_INSTALL_REQ)
        return false;
    if (path[0] == '/')
        snprintf(s_path, sizeof(s_path), "%s", path);
    else
        snprintf(s_path, sizeof(s_path), "/sdcard/%s", path);
    s_state = FPU_CHECKING;
    set_msg("CHECKING...");
    return true;
}

void fpgaupdate_commit(void)
{
    if (s_state == FPU_READY) {
        s_state = FPU_INSTALL_REQ;
        s_dirty = true;
    }
}

void fpgaupdate_cancel(void)
{
    if (s_state == FPU_READY || s_state == FPU_ERROR) {
        s_state = FPU_IDLE;
        set_msg("");
    }
}

fpu_state_t fpgaupdate_state(void)   { return s_state; }
const char *fpgaupdate_message(void) { return s_msg; }

bool fpgaupdate_dirty(void)
{
    static fpu_state_t last = FPU_IDLE;
    bool d = s_dirty || s_state != last;
    s_dirty = false;
    last = s_state;
    return d;
}

/* ---- state machine ------------------------------------------------------- */
static bool check_file(void)
{
    FILE *f = fopen(s_path, "rb");
    if (!f) {
        fail("CANNOT OPEN FILE");
        return false;
    }
    fseek(f, 0, SEEK_END);
    s_size = (uint32_t)ftell(f);
    fseek(f, 0, SEEK_SET);

    static uint8_t hdr[FPU_HDR_SCAN];
    size_t br = fread(hdr, 1, sizeof(hdr), f);
    fclose(f);
    if (br < 64) {
        fail("READ ERROR");
        return false;
    }
    if (memcmp(hdr, "BFNP", 4) == 0) {
        fail("THAT IS MCU FIRMWARE, NOT FPGA");
        return false;
    }
    if (s_size < FPU_MIN_SIZE || s_size > FPU_MAX_SIZE) {
        fail("BAD FILE SIZE");
        return false;
    }
    /* Gowin sync word, then the embedded GW5AT-60 IDCODE somewhere in the
     * header window (GW5A .fs header layout differs from GW2A, so scan
     * rather than assume a fixed offset from the sync word). */
    int sync = -1;
    for (int i = 0; i + 2 <= (int)br; i++) {
        if (hdr[i] == 0xA5 && hdr[i + 1] == 0xC3) {
            sync = i;
            break;
        }
    }
    if (sync < 0) {
        fail("NOT A GOWIN BITSTREAM");
        return false;
    }
    bool id_found = false;
    for (int i = 0; i + 4 <= (int)br; i++) {
        if (hdr[i] == 0x00 && hdr[i + 1] == 0x01 &&
            hdr[i + 2] == 0x48 && hdr[i + 3] == 0x1B) {
            id_found = true;
            break;
        }
    }
    if (!id_found) {
        fail("BITSTREAM IS FOR ANOTHER FPGA");
        return false;
    }
    s_state = FPU_READY;
    set_msg("READY: %lu BYTES", (unsigned long)s_size);
    osd_log("FPGA: VERIFIED %lu BYTES", (unsigned long)s_size);
    return true;
}

static void install(void)
{
    FILE *f = fopen(s_path, "rb");
    if (!f) {
        fail("CANNOT OPEN FILE");
        return;
    }

    osd_log("FPGA: INSTALLING - SCREEN GOES DARK");
    vTaskDelay(pdMS_TO_TICKS(500));      /* let the warning page land */

    fpga_jtag_init_pins();

    /* Probe the live FPGA before killing it. */
    uint32_t id = fpga_jtag_idcode();
    if (id != FPGA_JTAG_IDCODE_GW5AT60) {
        fclose(f);
        ESP_LOGE(TAG, "live IDCODE %08lx != GW5AT-60", (unsigned long)id);
        fail("JTAG IDCODE MISMATCH");
        return;
    }

    if (!fpga_jtag_flash_enter()) {      /* fabric dies here */
        fclose(f);
        fpga_jtag_reload();              /* try to come back up */
        fail("COULD NOT ENTER FLASH MODE");
        return;
    }

    /* From here the screen is dark and there is no way back to the old
     * bitstream except finishing (flash is erased block by block). */
    bool ok = true;
    for (uint32_t a = 0; ok && a < s_size; a += FPU_BLOCK)
        ok = flash_erase_block(a);
    if (!ok) {
        fclose(f);
        fail("ERASE TIMEOUT");
        return;
    }

    uint32_t addr = 0;
    while (ok && addr < s_size) {
        memset(s_page, 0xFF, sizeof(s_page));
        size_t br = fread(s_page, 1, FPU_PAGE, f);
        if (br == 0) {
            ok = false;
            break;
        }
        for (int attempt = 0; attempt < 2; attempt++) {
            if (!flash_program_page(addr, s_page, br)) {
                ok = false;
                break;
            }
            fpga_jtag_flash_read(addr, s_back, br);
            if (memcmp(s_page, s_back, br) == 0)
                break;
            if (attempt == 1)
                ok = false;
        }
        addr += br;
        if ((addr & 0xFFFF) == 0)
            vTaskDelay(1);               /* feed the watchdog */
    }
    fclose(f);

    if (!ok) {
        /* Old bitstream already erased: FPGA will come up unconfigured.
         * The ESP32 stays alive; openFPGALoader over USB-C is the
         * recovery path. */
        fail("PROGRAM/VERIFY FAILED - USB FLASH NEEDED");
        return;
    }

    osd_log("FPGA: DONE, RELOADING");
    fpga_jtag_reload();                  /* boot the new bitstream */
    vTaskDelay(pdMS_TO_TICKS(2000));
    s_state = FPU_IDLE;
    esp_restart();                       /* clean full-system bring-up */
}

void fpgaupdate_poll(void)
{
    switch (s_state) {
    case FPU_CHECKING:
        check_file();
        break;
    case FPU_INSTALL_REQ:
        install();
        break;
    default:
        break;
    }
}
