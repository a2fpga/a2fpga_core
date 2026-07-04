/*
 * fwupdate.c — see fwupdate.h for the two-phase design.
 */
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "ff.h"
#include "bflb_flash.h"
#include "bflb_irq.h"

#include "osd_console.h"
#include "fwupdate.h"

/* Flash layout (4 MB part; settings live in the last 4 KB sector):
 *   0x000000  Sipeed Stage-1 bootloader (never touched)
 *   0x040000  application (XIP)                       <- FWU_APP_ADDR
 *   0x200000  update staging area                     <- FWU_STAGE_ADDR
 *   0x3FF000  settings blob (settings.c)
 */
#define FWU_APP_ADDR    0x040000u
#define FWU_STAGE_ADDR  0x200000u
#define FWU_MAX_SIZE    (FWU_STAGE_ADDR - FWU_APP_ADDR)   /* 1.75 MB */
#define FWU_MIN_SIZE    0x10000u                          /* sanity   */
#define FWU_CHUNK       4096u

static volatile fwu_state_t s_state = FWU_IDLE;
static char     s_path[132];          /* "0:/" + relative path */
static char     s_msg[41];
static FIL      s_file;
static bool     s_file_open;
static uint32_t s_size;
static uint32_t s_off;                /* staging/verify position */
static uint32_t s_crc;                /* running CRC             */
static uint32_t s_file_crc;           /* CRC of the file         */
static bool     s_dirty = true;
static uint8_t  s_buf[FWU_CHUNK];

/* CRC-32 (IEEE), running form. Also compiled into TCM for the commit-time
 * verify, when no flash-resident code may execute. */
__attribute__((noinline))
static uint32_t ATTR_TCM_SECTION crc32_step(uint32_t crc, const uint8_t *p,
                                            uint32_t n)
{
    while (n--) {
        crc ^= *p++;
        for (int i = 0; i < 8; i++)
            crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
    return crc;
}

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
    if (s_file_open) {
        f_close(&s_file);
        s_file_open = false;
    }
    s_state = FWU_ERROR;
    set_msg("%s", why);
    osd_log("FWUPDATE: %s", why);
}

/* ---- the point of no return --------------------------------------------
 * Runs entirely from TCM with interrupts disabled: the XIP app region is
 * erased and rewritten underneath us. Only TCM-resident SDK calls are used
 * (bflb_flash_*, bflb_irq_*, GLB_SW_POR_Reset — all ATTR_TCM_SECTION).
 * Never returns. */
/* noinline is LOAD-BEARING: without it GCC inlines this single-call static
 * into fwupdate_poll (flash-resident), silently discarding the TCM section —
 * and the commit loop would execute from the region it is erasing. */
__attribute__((noinline))
static void ATTR_TCM_SECTION commit_tcm(uint32_t len, uint32_t want_crc)
{
    uintptr_t flags = bflb_irq_save();

    for (int attempt = 0; attempt < 2; attempt++) {
        for (uint32_t off = 0; off < len; off += FWU_CHUNK) {
            uint32_t n = len - off;
            if (n > FWU_CHUNK)
                n = FWU_CHUNK;
            bflb_flash_read(FWU_STAGE_ADDR + off, s_buf, n);
            bflb_flash_erase(FWU_APP_ADDR + off, FWU_CHUNK);
            bflb_flash_write(FWU_APP_ADDR + off, s_buf, n);
        }
        /* verify */
        uint32_t crc = 0xFFFFFFFFu;
        for (uint32_t off = 0; off < len; off += FWU_CHUNK) {
            uint32_t n = len - off;
            if (n > FWU_CHUNK)
                n = FWU_CHUNK;
            bflb_flash_read(FWU_APP_ADDR + off, s_buf, n);
            crc = crc32_step(crc, s_buf, n);
        }
        if (~crc == want_crc)
            break;
        /* mismatch: one retry; after that reboot anyway — recovery is the
         * UPDATE-button boot mode, same as a mid-commit power loss */
    }

    (void)flags;

    /* Bare-register reset (GLB_SWRST_CFG2 @ 0x20000548): the SDK's
     * GLB_SW_POR_Reset does clock switching first via ROM-API trampolines,
     * and the first field test froze at this point — keep the danger zone
     * down to three volatile stores with no callees. PWRON_RST (bit 0)
     * triggers on the 0->1 edge; fall back to CHIP/SYS reset bits if we are
     * somehow still executing. */
    {
        volatile uint32_t *swrst = (volatile uint32_t *)(0x20000000u + 0x548u);
        uint32_t v = *swrst;
        *swrst = v & ~0x01u;          /* clear pwron_rst  */
        *swrst = v | 0x01u;           /* rising edge: POR */
        for (volatile int i = 0; i < 1000000; i++) { }
        *swrst = v | 0x24u;           /* chip+sys reset fallback */
    }
    while (1) { }
}

/* ---- public API ---------------------------------------------------------- */
bool fwupdate_request(const char *path)
{
    if (s_state == FWU_STAGING || s_state == FWU_VERIFYING ||
        s_state == FWU_COMMIT_REQ)
        return false;
    snprintf(s_path, sizeof(s_path), "0:/%s", path);
    s_state = FWU_STAGING;   /* opened by the disk thread in poll */
    s_off = 0;
    s_size = 0;
    s_crc = 0xFFFFFFFFu;
    set_msg("STAGING...");
    return true;
}

void fwupdate_commit(void)
{
    if (s_state == FWU_STAGED) {
        s_state = FWU_COMMIT_REQ;
        s_dirty = true;
    }
}

void fwupdate_cancel(void)
{
    if (s_state == FWU_STAGED || s_state == FWU_ERROR) {
        s_state = FWU_IDLE;
        set_msg("");
    }
}

fwu_state_t fwupdate_state(void) { return s_state; }

int fwupdate_progress(void)
{
    if (!s_size)
        return 0;
    return (int)((uint64_t)s_off * 100u / s_size);
}

const char *fwupdate_message(void) { return s_msg; }

bool fwupdate_dirty(void)
{
    static int last_pct = -1;
    static fwu_state_t last_state = FWU_IDLE;
    bool d = s_dirty || fwupdate_progress() != last_pct ||
             s_state != last_state;
    s_dirty = false;
    last_pct = fwupdate_progress();
    last_state = s_state;
    return d;
}

/* ---- disk-thread state machine ------------------------------------------ */
void fwupdate_poll(void)
{
    UINT br;

    switch (s_state) {

    case FWU_STAGING:
        if (!s_file_open) {
            if (f_open(&s_file, s_path, FA_READ) != FR_OK) {
                fail("CANNOT OPEN FILE");
                return;
            }
            s_file_open = true;
            s_size = (uint32_t)f_size(&s_file);
            if (s_size < FWU_MIN_SIZE || s_size > FWU_MAX_SIZE) {
                fail("BAD FILE SIZE");
                return;
            }
            osd_log("FWUPDATE: STAGING %s (%lu B)", s_path + 3,
                    (unsigned long)s_size);
        }
        /* one chunk per poll: disk serving stays responsive */
        br = 0;
        if (f_read(&s_file, s_buf, FWU_CHUNK, &br) != FR_OK || br == 0) {
            fail("READ ERROR");
            return;
        }
        if (s_off == 0) {
            /* Bouffalo bootheader magic, and it must match the installed
             * app (same image type Stage-1 chain-loads today) */
            uint8_t cur[4];
            if (memcmp(s_buf, "BFNP", 4) != 0 ||
                bflb_flash_read(FWU_APP_ADDR, cur, 4) != 0 ||
                memcmp(s_buf, cur, 4) != 0) {
                fail("NOT A FIRMWARE IMAGE");
                return;
            }
        }
        if (bflb_flash_erase(FWU_STAGE_ADDR + s_off, FWU_CHUNK) != 0 ||
            bflb_flash_write(FWU_STAGE_ADDR + s_off, s_buf, br) != 0) {
            fail("FLASH WRITE ERROR");
            return;
        }
        s_crc = crc32_step(s_crc, s_buf, br);
        s_off += br;
        set_msg("STAGING %d%%", fwupdate_progress());
        if (s_off >= s_size) {
            f_close(&s_file);
            s_file_open = false;
            s_file_crc = ~s_crc;
            s_state = FWU_VERIFYING;
            s_off = 0;
            s_crc = 0xFFFFFFFFu;
        }
        break;

    case FWU_VERIFYING: {
        uint32_t n = s_size - s_off;
        if (n > FWU_CHUNK)
            n = FWU_CHUNK;
        if (bflb_flash_read(FWU_STAGE_ADDR + s_off, s_buf, n) != 0) {
            fail("VERIFY READ ERROR");
            return;
        }
        s_crc = crc32_step(s_crc, s_buf, n);
        s_off += n;
        set_msg("VERIFYING %d%%", fwupdate_progress());
        if (s_off >= s_size) {
            if (~s_crc != s_file_crc) {
                fail("VERIFY MISMATCH");
                return;
            }
            s_state = FWU_STAGED;
            set_msg("READY: %lu BYTES VERIFIED", (unsigned long)s_size);
            osd_log("FWUPDATE: STAGED OK (%lu B)", (unsigned long)s_size);
        }
        break;
    }

    case FWU_COMMIT_REQ:
        osd_log("FWUPDATE: INSTALLING - DO NOT POWER OFF");
        s_state = FWU_IDLE;   /* moot — commit_tcm never returns */
        commit_tcm(s_size, s_file_crc);
        break;

    default:
        break;
    }
}
