/*
 * fpgastream.c — network bitstream flashing over TCP (bench tool).
 *
 * Streams a Gowin .bin into the GW5AT-60's external SPI config flash via
 * the bit-banged JTAG driver (fpga_jtag.c), fed from a socket instead of
 * a file: 1.0a3 has no SD card and LittleFS (1.875 MB) cannot stage a
 * ~2.3 MB image, so pages are programmed as bytes arrive and TCP flow
 * control paces the sender. Eliminates the Mac/USB replug cycle for
 * bench flashing entirely.
 *
 * Safety properties mirror fpgaupdate.c (same ancestry):
 *  - header validated BEFORE anything is touched: Gowin A5C3 sync word +
 *    embedded SOM IDCODE (GW5AT-60 or GW5AST-138) in the first 4 KB, and
 *    the live JTAG IDCODE must match the image's — plus a live JTAG IDCODE
 *    probe of the FPGA itself;
 *  - every page read back and compared after programming, one retry;
 *  - success: JTAG RELOAD boots the new bitstream, ESP32 restarts for a
 *    clean bring-up (the closing "OK" is flushed first);
 *  - a failed/aborted stream leaves the FPGA unconfigured but the ESP32
 *    alive; recovery = re-run the stream (or 'fpgaerase' / USB tools).
 *
 * The flash primitives are duplicated from fpgaupdate.c (they are static
 * there); if a third user appears, hoist them into fpga_jtag.c.
 */
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_system.h"
#include "esp_log.h"
#include "lwip/sockets.h"

#include "osd_console.h"
#include "fpga_jtag.h"
#include "fpgaupdate.h"
#include "fpgastream.h"
#include "disk.h"

static const char *TAG = "fpgastrm";

#define FS_PORT      2323
#define FS_PAGE      256u
#define FS_BLOCK     65536u
#define FS_MIN_SIZE  (512u * 1024u)
#define FS_MAX_SIZE  (8u * 1024u * 1024u)
#define FS_HDR_SCAN  4096u

/* ---- SPI flash primitives over fpga_jtag_spi_xfer ----------------------- */
static void flash_write_enable(void)
{
    fpga_jtag_spi_xfer(0x06, NULL, NULL, 0);
}

static bool flash_wait_busy(uint32_t loops)
{
    uint32_t n = 0;
    while (loops--) {
        uint8_t rx = 0xFF;
        fpga_jtag_spi_xfer(0x05, NULL, &rx, 1);
        if (!(rx & 0x01))
            return true;
        if ((++n & 0x3FF) == 0)
            vTaskDelay(1);               /* yield on long erases */
    }
    return false;
}

static bool flash_erase_block(uint32_t addr)
{
    flash_write_enable();
    uint8_t tx[3] = { (uint8_t)(addr >> 16), (uint8_t)(addr >> 8),
                      (uint8_t)addr };
    fpga_jtag_spi_xfer(0xD8, tx, NULL, 3);
    if (!flash_wait_busy(60000)) {
        ESP_LOGE(TAG, "erase timeout at block 0x%06lx", (unsigned long)addr);
        return false;
    }
    return true;
}

static bool flash_program_page(uint32_t addr, const uint8_t *data, uint32_t n)
{
    uint8_t tx[3 + FS_PAGE];
    flash_write_enable();
    tx[0] = (uint8_t)(addr >> 16);
    tx[1] = (uint8_t)(addr >> 8);
    tx[2] = (uint8_t)addr;
    memcpy(tx + 3, data, n);
    fpga_jtag_spi_xfer(0x02, tx, NULL, 3 + n);
    return flash_wait_busy(4000);
}

/* ---- socket helpers ------------------------------------------------------ */
static bool send_str(int fd, const char *s)
{
    size_t n = strlen(s);
    return send(fd, s, n, 0) == (ssize_t)n;
}

static bool recv_full(int fd, uint8_t *dst, uint32_t n)
{
    while (n) {
        ssize_t r = recv(fd, dst, n, 0);
        if (r <= 0)
            return false;
        dst += r;
        n -= (uint32_t)r;
    }
    return true;
}

/* Read the ASCII header line "FPGA <size>\n" (CR tolerated). */
static bool recv_header(int fd, uint32_t *size)
{
    char line[32];
    size_t k = 0;
    while (k < sizeof(line) - 1) {
        char c;
        if (recv(fd, &c, 1, 0) != 1)
            return false;
        if (c == '\n')
            break;
        if (c != '\r')
            line[k++] = c;
    }
    line[k] = 0;
    unsigned long sz = 0;
    if (sscanf(line, "FPGA %lu", &sz) != 1)
        return false;
    *size = (uint32_t)sz;
    return true;
}

/* ---- header validation (same rules as fpgaupdate check_file) ------------- */
static const char *validate_hdr(const uint8_t *hdr, uint32_t n, uint32_t size,
                                uint32_t *chip_id)
{
    if (n >= 4 && memcmp(hdr, "BFNP", 4) == 0)
        return "MCU FIRMWARE NOT FPGA";
    if (size < FS_MIN_SIZE || size > FS_MAX_SIZE)
        return "BAD SIZE";
    bool sync = false;
    for (uint32_t i = 0; i + 2 <= n && !sync; i++)
        if (hdr[i] == 0xA5 && hdr[i + 1] == 0xC3)
            sync = true;
    if (!sync)
        return "NOT A GOWIN BITSTREAM";
    /* The image's embedded IDCODE names the die it was built for; the live
     * chip must match it exactly (chip_id), so a 60B image can never land
     * on a 138B SOM or vice versa. */
    uint32_t id = 0;
    for (uint32_t i = 0; i + 4 <= n && !id; i++) {
        if (hdr[i] != 0x00 || hdr[i + 1] != 0x01 || hdr[i + 3] != 0x1B)
            continue;
        uint32_t w = 0x00010000u | ((uint32_t)hdr[i + 2] << 8) | 0x1Bu;
        if (w == FPGA_JTAG_IDCODE_GW5AT60 || w == FPGA_JTAG_IDCODE_GW5AST138 || w == FPGA_JTAG_IDCODE_GW5A25)
            id = w;
    }
    if (!id)
        return "BITSTREAM FOR ANOTHER FPGA";
    *chip_id = id;
    return NULL;
}

/* ---- one streaming session ----------------------------------------------- */
static uint8_t s_hdr[FS_HDR_SCAN];
static uint8_t s_page[FS_PAGE];
static uint8_t s_back[FS_PAGE];

/* Pull n bytes for the programming loop: drain the buffered header first,
 * then the socket. */
static bool pull(int fd, uint32_t *hdr_off, uint32_t hdr_len,
                 uint8_t *dst, uint32_t n)
{
    while (n && *hdr_off < hdr_len) {
        *dst++ = s_hdr[(*hdr_off)++];
        n--;
    }
    return n ? recv_full(fd, dst, n) : true;
}

static void serve_one(int fd)
{
    uint32_t size = 0;
    if (!recv_header(fd, &size)) {
        send_str(fd, "ERR BAD HEADER\n");
        return;
    }

    uint32_t hdr_len = size < FS_HDR_SCAN ? size : FS_HDR_SCAN;
    if (!recv_full(fd, s_hdr, hdr_len)) {
        send_str(fd, "ERR SHORT READ\n");
        return;
    }
    uint32_t want_id = 0;
    const char *why = validate_hdr(s_hdr, hdr_len, size, &want_id);
    if (why) {
        char m[64];
        snprintf(m, sizeof(m), "ERR %s\n", why);
        send_str(fd, m);
        return;
    }

    if (fpgaupdate_state() != FPU_IDLE) {
        send_str(fd, "ERR UPDATER BUSY\n");
        return;
    }

    osd_log("FPGASTREAM: %lu BYTES - SCREEN GOES DARK",
            (unsigned long)size);
    ESP_LOGI(TAG, "stream install: %lu bytes", (unsigned long)size);

    /* Close the disk images and stop the disk task serving BEFORE the fabric
     * can go away (a full flash entry erases it; the reload below always
     * does). With the fabric gone, every register read returns bus junk and
     * the disk task used to act on it — on 2026-11-17 a junk write request
     * seeked 4 GB past the end of disk1.nib during the reload wait below and
     * FatFS extended the file into the stick's root directory
     * (boards/a2p25/docs/STICK_CORRUPTION_2026-11-17.md). */
    disk_quiesce();

    /* GW5A auto-boot scanner race (native edition of the openFPGALoader
     * saga): an UNCONFIGURED chip — e.g. after an interrupted stream
     * left flash partially written — retries flash boot continuously,
     * and its config engine races our JTAG-SPI passthrough: IDCODE
     * reads garbage, flash mode won't enter. Settle-and-retry until
     * entry wins. Winning ONCE is enough: the first erased block
     * destroys the boot header, and the scanner stays quiet for the
     * rest of the operation. (A configured chip parks its config
     * engine and enters on the first try, as before.) */
    bool entered = false;
    uint32_t id = 0;
    uint8_t jedec[3] = { 0, 0, 0 };
    for (int try_n = 0; try_n < 10 && !entered; try_n++) {
        if (try_n > 0) {
            fpga_jtag_release_pins();
            vTaskDelay(pdMS_TO_TICKS(700));
        }
        fpga_jtag_init_pins();
        vTaskDelay(pdMS_TO_TICKS(try_n == 0 ? 100 : 400));
        id = fpga_jtag_idcode();
        if (id != want_id) {
            osd_log("FS TRY%d IDCODE %08lX (want %08lX)", try_n,
                    (unsigned long)id, (unsigned long)want_id);
            continue;
        }
        /* KEEPSRAM entry first (tries 0-4): a configured fabric keeps
         * the boot engine satisfied, so it never re-arms auto-boot from
         * the valid flash image mid-operation — on the GW5AST-138 a
         * full SRAM-erase entry re-arms it immediately and the config
         * engine owns the SPI bus (dead passthrough on EVERY attempt
         * with a bootable image in flash; blank-flash streams were
         * unaffected — live-hit B3 08-20). Fall back to the full
         * enter (tries 5+) for the blank/unconfigured-chip case where
         * there is no fabric to keep. */
        if (try_n < 5) {
            if (!fpga_jtag_flash_enter_keepsram())
                continue;
        } else {
            if (!fpga_jtag_flash_enter())   /* fabric (if any) dies here */
                continue;
        }
        /* Entry alone is not proof the JTAG->SPI passthrough is live:
         * a dead passthrough returns all-ones, which reads as
         * busy-forever in the erase poll (live-hit: ERASE FAILED with
         * flash content untouched, B3/138K 08-20). Verify with a JEDEC
         * ID read before trusting the path. */
        fpga_jtag_spi_xfer(0x9F, NULL, jedec, 3);
        if ((jedec[0] == 0xFF && jedec[1] == 0xFF) ||
            (jedec[0] == 0x00 && jedec[1] == 0x00)) {
            osd_log("FS TRY%d %s ID OK JEDEC %02X%02X%02X", try_n,
                    try_n < 5 ? "KEEP" : "FULL",
                    jedec[0], jedec[1], jedec[2]);
            continue;
        }
        entered = true;
    }
    if (!entered) {
        fpga_jtag_release_pins();
        disk_request_remount();   /* fabric may still be alive (keepsram) */
        char em[64];
        osd_log("FS TRYEND ID %08lX JEDEC %02X%02X%02X",
                (unsigned long)id, jedec[0], jedec[1], jedec[2]);
        snprintf(em, sizeof(em), "ERR JTAG ENTRY id=%08lx jedec=%02x%02x%02x\n",
                 (unsigned long)id, jedec[0], jedec[1], jedec[2]);
        send_str(fd, em);
        return;
    }
    ESP_LOGI(TAG, "flash JEDEC %02x%02x%02x", jedec[0], jedec[1], jedec[2]);
    osd_log("FPGASTREAM: FLASH JEDEC %02X%02X%02X",
            jedec[0], jedec[1], jedec[2]);

    bool ok = true;
    for (uint32_t a = 0; ok && a < size; a += FS_BLOCK) {
        ok = flash_erase_block(a);
        if ((a % (FS_BLOCK * 8u)) == 0)
            vTaskDelay(1);
    }
    if (!ok) {
        fpga_jtag_release_pins();
        send_str(fd, "ERR ERASE\n");
        osd_log("FPGASTREAM: ERASE FAILED");
        disk_request_remount();   /* serve again if the fabric survived */
        return;
    }
    send_str(fd, "E\n");

    uint32_t hdr_off = 0;
    uint32_t addr = 0;
    while (ok && addr < size) {
        uint32_t n = size - addr < FS_PAGE ? size - addr : FS_PAGE;
        memset(s_page, 0xFF, sizeof(s_page));
        if (!pull(fd, &hdr_off, hdr_len, s_page, n)) {
            ok = false;
            break;
        }
        for (int attempt = 0; attempt < 2; attempt++) {
            if (!flash_program_page(addr, s_page, n)) {
                ok = false;
                break;
            }
            fpga_jtag_flash_read(addr, s_back, n);
            if (memcmp(s_page, s_back, n) == 0)
                break;
            if (attempt == 1)
                ok = false;
        }
        addr += n;
        if ((addr & 0xFFFF) == 0) {
            char m[24];
            snprintf(m, sizeof(m), "P %lu\n", (unsigned long)addr);
            send_str(fd, m);
            vTaskDelay(1);
        }
    }

    if (!ok) {
        fpga_jtag_release_pins();
        send_str(fd, "ERR PROGRAM/VERIFY\n");
        osd_log("FPGASTREAM: FAILED AT %luK - RERUN OR fpgaerase",
                (unsigned long)(addr >> 10));
        disk_request_remount();   /* serve again if the fabric survived */
        return;
    }

    send_str(fd, "OK\n");
    osd_log("FPGASTREAM: DONE, RELOADING");
    vTaskDelay(pdMS_TO_TICKS(500));      /* flush the OK */
    close(fd);
    fpga_jtag_reload();                  /* boot the new bitstream */
    vTaskDelay(pdMS_TO_TICKS(2000));
    disk_release_storage();              /* images closed above; detach the stick's FAT */
    esp_restart();                       /* clean full-system bring-up */
}

/* ---- listener task ------------------------------------------------------- */
static void fpgastream_task(void *arg)
{
    (void)arg;
    int ls = -1;
    for (;;) {
        if (ls < 0) {
            ls = socket(AF_INET, SOCK_STREAM, 0);
            if (ls < 0) {
                vTaskDelay(pdMS_TO_TICKS(2000));
                continue;
            }
            int one = 1;
            setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
            struct sockaddr_in a = { 0 };
            a.sin_family = AF_INET;
            a.sin_addr.s_addr = htonl(INADDR_ANY);
            a.sin_port = htons(FS_PORT);
            if (bind(ls, (struct sockaddr *)&a, sizeof(a)) < 0 ||
                listen(ls, 1) < 0) {
                close(ls);
                ls = -1;
                vTaskDelay(pdMS_TO_TICKS(2000));  /* lwIP not up yet */
                continue;
            }
            ESP_LOGI(TAG, "listening on %u", FS_PORT);
        }
        int fd = accept(ls, NULL, NULL);
        if (fd < 0) {
            vTaskDelay(pdMS_TO_TICKS(500));
            continue;
        }
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        serve_one(fd);
        close(fd);
    }
}

void fpgastream_start(void)
{
    xTaskCreatePinnedToCore(fpgastream_task, "fpgastream", 8192, NULL, 3,
                            NULL, 1);
}
