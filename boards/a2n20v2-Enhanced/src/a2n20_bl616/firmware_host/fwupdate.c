/*
 * fwupdate.c — see fwupdate.h for the two-phase design.
 */
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "ff.h"
#include "bflb_flash.h"
#include "bflb_irq.h"
#include "bflb_l1c.h"

#include "usb_osal.h"
#include "usbh_core.h"
#include "bl616_hbn.h"
#include "bl616_glb.h"
#include "bl616_pds.h"

#include "osd_console.h"
#include "fwupdate.h"

/* Flash layout (4 MB part; settings live in the last 4 KB sector):
 *   0x000000  Sipeed Stage-1 bootloader (never touched)
 *   0x040000  application (XIP)                       <- FWU_APP_ADDR
 *   0x200000  update staging area                     <- FWU_STAGE_ADDR
 *   0x3FF000  settings blob (settings.c)
 */
#define FWU_STAGE_ADDR  0x200000u
#define FWU_MIN_SIZE    0x10000u                          /* sanity   */
#define FWU_CHUNK       4096u

/* Where does the RUNNING image live in flash? Not a constant: chain-loaded
 * boards (fused Sipeed Stage 1, or friend_20k on unfused boards) run us
 * from 0x40000, but a standalone unfused install runs us from 0x0. The
 * update must be written where THIS image boots from, and the flash
 * controller knows: Stage 1 / BootROM programmed the XIP image offset,
 * which maps flash base+0x1000 (the boot header occupies the first 4 KB)
 * to the code window. */
uint32_t fwupdate_app_base(void)
{
    uint32_t off = bflb_flash_get_image_offset();
    return off >= 0x1000u ? off - 0x1000u : 0u;
}

static bool app_base_sane(uint32_t base)
{
    return base == 0x0u || base == 0x040000u;
}

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
static volatile bool s_restart_req;
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

/* Software restart by jumping to the app entry at the XIP base. No chip
 * reset is involved (none fires on fused boards): with interrupts hard-off
 * and both caches cleaned/invalidated (the icache still holds lines of the
 * OLD image after an update!), transferring control to the entry point
 * re-runs the app's startup exactly as Stage-1's chain-load does. noinline
 * is LOAD-BEARING (see commit_tcm). */
#define FWU_APP_ENTRY  0xA0000000u

__attribute__((noinline))
void ATTR_TCM_SECTION fwupdate_restart_app(void)
{
    __asm volatile ("csrci mstatus, 8");   /* MIE off, no going back */

    bflb_l1c_dcache_clean_all();
    bflb_l1c_dcache_invalidate_all();
    bflb_l1c_icache_invalid_all();

    ((void (*)(void))FWU_APP_ENTRY)();
    while (1) { }
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
static void ATTR_TCM_SECTION commit_tcm(uint32_t app_base, uint32_t len,
                                        uint32_t want_crc)
{
    uintptr_t flags = bflb_irq_save();

    for (int attempt = 0; attempt < 2; attempt++) {
        for (uint32_t off = 0; off < len; off += FWU_CHUNK) {
            uint32_t n = len - off;
            if (n > FWU_CHUNK)
                n = FWU_CHUNK;
            bflb_flash_read(FWU_STAGE_ADDR + off, s_buf, n);
            bflb_flash_erase(app_base + off, FWU_CHUNK);
            bflb_flash_write(app_base + off, s_buf, n);
        }
        /* verify */
        uint32_t crc = 0xFFFFFFFFu;
        for (uint32_t off = 0; off < len; off += FWU_CHUNK) {
            uint32_t n = len - off;
            if (n > FWU_CHUNK)
                n = FWU_CHUNK;
            bflb_flash_read(app_base + off, s_buf, n);
            crc = crc32_step(crc, s_buf, n);
        }
        if (~crc == want_crc)
            break;
        /* mismatch: one retry; after that reboot anyway — recovery is the
         * UPDATE-button boot mode, same as a mid-commit power loss */
    }

    (void)flags;
    fwupdate_restart_app();
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

void fwupdate_request_restart(void)
{
    s_restart_req = true;
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

    if (s_restart_req && s_state != FWU_COMMIT_REQ) {
        osd_log("FWUPDATE: RESTARTING");
        usb_osal_msleep(200);
        usbh_deinitialize(0);
        /* Drop VBUS and hold it low so the (bus-powered) hub and devices
         * get a REAL power cycle, not the ~10 ms brownout of the driver's
         * init dance — a brownout zombies the hub's port controller (EP0
         * answers, ports report unpowered, SET PORT_POWER is a no-op).
         * The relaunched app's usb_hc_low_level_init restores VBUS. */
        {
            volatile uint32_t *otg = (volatile uint32_t *)(0x20072080u);
            uint32_t v = *otg;
            v |= (1u << 5);            /* USB_A_BUS_DROP_HOV */
            v &= ~(1u << 4);           /* USB_A_BUS_REQ_HOV  */
            *otg = v;
            usb_osal_msleep(1000);
        }
        /* Hardware-reset the USB block (peripheral-level GLB reset — works
         * regardless of the fused chip-reset situation). The relaunched
         * app's usb_hc_low_level_init assumes power-on PHY/OTG state; a
         * soft usbh_deinitialize alone leaves the port unable to detect
         * devices. Also chops any in-flight EHCI DMA before RAM is reused. */
        GLB_AHB_MCU_Software_Reset(GLB_AHB_MCU_SW_EXT_USB);
        /* Power the PHY off (PDS domain — untouched by the GLB reset).
         * bflb_usb_phy_init only ORs the power bits in, so unless they
         * start at 0 the "power-up" is a no-op and the port never detects
         * devices after a restart. */
        PDS_Turn_Off_USB();
        fwupdate_restart_app();
    }

    switch (s_state) {

    case FWU_STAGING:
        if (!s_file_open) {
            if (f_open(&s_file, s_path, FA_READ) != FR_OK) {
                fail("CANNOT OPEN FILE");
                return;
            }
            s_file_open = true;
            s_size = (uint32_t)f_size(&s_file);
            uint32_t base = fwupdate_app_base();
            if (!app_base_sane(base)) {
                fail("UNKNOWN FLASH LAYOUT");
                return;
            }
            if (s_size < FWU_MIN_SIZE ||
                s_size > FWU_STAGE_ADDR - base) {
                fail("BAD FILE SIZE");
                return;
            }
            osd_log("FWUPDATE: APP BASE 0x%lX", (unsigned long)base);
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
                bflb_flash_read(fwupdate_app_base(), cur, 4) != 0 ||
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
        /* Let the menu finish painting its final instructions, then prepare
         * the warm-boot environment (per FPGA-Companion's proven recipe):
         * tear down the USB host stack and clear the HBN user-boot override
         * — the HBN domain survives warm resets and a stale boot-config
         * there redirects the BootROM away from flash boot. */
        usb_osal_msleep(500);
        usbh_deinitialize(0);
        GLB_AHB_MCU_Software_Reset(GLB_AHB_MCU_SW_EXT_USB);
        PDS_Turn_Off_USB();
        HBN_Set_User_Boot_Config(0);
        s_state = FWU_IDLE;   /* moot — commit_tcm never returns */
        commit_tcm(fwupdate_app_base(), s_size, s_file_crc);
        break;

    default:
        break;
    }
}
