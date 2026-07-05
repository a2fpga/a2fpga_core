/*
 * fpgaupdate.c — FPGA bitstream self-update from the storage volume.
 *
 * Writes a Gowin .bin (the raw flash image the build emits at
 * impl/pnr/<board>.bin — verbatim at offset 0, verified on hardware) into
 * the GW2AR's external W25Q64 config flash over bit-banged SPI-over-JTAG
 * (fpga_jtag.c). Unlike the MCU updater there is no staging step: the
 * running bitstream must be killed (SRAM erase) before the flash is even
 * reachable, so the screen and Apple II are down for the whole write
 * (~1-2 min). The menu paints a full-screen warning first.
 *
 * Safety properties:
 *  - CHECK phase validates the file BEFORE anything is touched: Gowin
 *    A5C3 sync word near the start, embedded IDCODE == GW2A(R)-18, and a
 *    "BFNP" reject so an MCU firmware .bin can't be flashed by mistake.
 *  - Every page is read back and compared immediately after programming,
 *    with one retry (erase of a page is not possible; retry re-programs —
 *    a persistent mismatch aborts).
 *  - On success: JTAG RELOAD boots the new bitstream, then the MCU
 *    restarts itself (fwupdate_restart_app path) for a clean bring-up.
 *  - An interrupted/failed write leaves the FPGA unconfigured but the
 *    BL616 fully alive; recovery is the PC flash procedure (tools/flash.sh
 *    with the Mac attached), documented in the README.
 */
#include <stdint.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "ff.h"
#include "usb_osal.h"
#include "osd_console.h"
#include "fpga_jtag.h"
#include "fwupdate.h"
#include "fpgaupdate.h"

#define FPU_MIN_SIZE   (256u * 1024u)
#define FPU_MAX_SIZE   (4u * 1024u * 1024u)
#define FPU_PAGE       256u
#define FPU_BLOCK      65536u

static volatile fpu_state_t s_state = FPU_IDLE;
static char     s_path[132];
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
}

/* ---- W25Q64 primitives over fpga_jtag_spi_xfer -------------------------- */
static void w25_write_enable(void)
{
    uint8_t tx = 0x06;
    fpga_jtag_spi_xfer(&tx, NULL, 1);
}

static bool w25_wait_busy(uint32_t loops)
{
    while (loops--) {
        uint8_t tx[2] = { 0x05, 0 };
        uint8_t rx[2] = { 0, 0xFF };
        fpga_jtag_spi_xfer(tx, rx, 2);
        if (!(rx[1] & 0x01))
            return true;
    }
    return false;
}

static bool w25_erase_block(uint32_t addr)
{
    w25_write_enable();
    uint8_t tx[4] = { 0xD8, (uint8_t)(addr >> 16), (uint8_t)(addr >> 8),
                      (uint8_t)addr };
    fpga_jtag_spi_xfer(tx, NULL, 4);
    return w25_wait_busy(20000);         /* block erase: up to ~2 s */
}

static bool w25_program_page(uint32_t addr, const uint8_t *data, uint32_t n)
{
    uint8_t tx[4 + FPU_PAGE];
    w25_write_enable();
    tx[0] = 0x02;
    tx[1] = (uint8_t)(addr >> 16);
    tx[2] = (uint8_t)(addr >> 8);
    tx[3] = (uint8_t)addr;
    memcpy(tx + 4, data, n);
    fpga_jtag_spi_xfer(tx, NULL, 4 + n);
    return w25_wait_busy(2000);          /* page program: ~0.7 ms typ */
}

/* ---- public API ---------------------------------------------------------- */
bool fpgaupdate_request(const char *path)
{
    if (s_state == FPU_CHECKING || s_state == FPU_INSTALL_REQ)
        return false;
    snprintf(s_path, sizeof(s_path), "0:/%s", path);
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

/* ---- disk-thread state machine ------------------------------------------ */
static bool check_file(void)
{
    FIL f;
    if (f_open(&f, s_path, FA_READ) != FR_OK) {
        fail("CANNOT OPEN FILE");
        return false;
    }
    s_size = (uint32_t)f_size(&f);
    uint8_t hdr[64];
    UINT br = 0;
    FRESULT fr = f_read(&f, hdr, sizeof(hdr), &br);
    f_close(&f);
    if (fr != FR_OK || br < sizeof(hdr)) {
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
    /* Gowin sync word within the leading 0xFF padding, then the embedded
     * device IDCODE 6 bytes after it: must be GW2A(R)-18 (0x0000081B). */
    int sync = -1;
    for (int i = 0; i + 10 <= (int)sizeof(hdr); i++) {
        if (hdr[i] == 0xA5 && hdr[i + 1] == 0xC3) {
            sync = i;
            break;
        }
    }
    if (sync < 0) {
        fail("NOT A GOWIN BITSTREAM (.BIN)");
        return false;
    }
    uint32_t id = ((uint32_t)hdr[sync + 6] << 24) |
                  ((uint32_t)hdr[sync + 7] << 16) |
                  ((uint32_t)hdr[sync + 8] << 8) |
                  (uint32_t)hdr[sync + 9];
    if (id != 0x0000081Bu) {
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
    FIL f;
    if (f_open(&f, s_path, FA_READ) != FR_OK) {
        fail("CANNOT OPEN FILE");
        return;
    }

    osd_log("FPGA: INSTALLING - SCREEN GOES DARK");
    usb_osal_msleep(500);                /* let the warning page land */

    fpga_jtag_init_pins();
    if (!fpga_jtag_flash_enter()) {      /* fabric dies here */
        f_close(&f);
        /* fabric may or may not still be up; reload to be safe */
        fpga_jtag_reload();
        fail("COULD NOT ENTER FLASH MODE");
        return;
    }

    /* From here the screen is dark and there is no way back to the old
     * bitstream except finishing (flash is erased block by block). */
    bool ok = true;
    for (uint32_t a = 0; ok && a < s_size; a += FPU_BLOCK)
        ok = w25_erase_block(a);
    if (!ok) {
        f_close(&f);
        fail("ERASE TIMEOUT");
        return;
    }

    uint32_t addr = 0;
    while (ok && addr < s_size) {
        UINT br = 0;
        memset(s_page, 0xFF, sizeof(s_page));
        if (f_read(&f, s_page, FPU_PAGE, &br) != FR_OK || br == 0) {
            ok = false;
            break;
        }
        for (int attempt = 0; attempt < 2; attempt++) {
            if (!w25_program_page(addr, s_page, br)) {
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
    }
    f_close(&f);

    if (!ok) {
        /* Old bitstream already erased: FPGA will come up unconfigured.
         * The BL616 stays alive; PC flash is the recovery path. */
        fail("PROGRAM/VERIFY FAILED - PC FLASH NEEDED");
        return;
    }

    osd_log("FPGA: DONE, RELOADING");
    fpga_jtag_reload();                  /* boot the new bitstream */
    usb_osal_msleep(2000);
    s_state = FPU_IDLE;
    fwupdate_request_restart();          /* clean full-system bring-up */
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
