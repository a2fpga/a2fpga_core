/*
 * disk.c — Apple II Disk II image serving (track-on-demand) for the host build.
 *
 * See disk.h for the architecture. Mirrors the NanoApple2 floppy_track model:
 * the FPGA requests one track at a time (lba = track*13, 13 * 512 = 0x1A00
 * bytes), we read it from the .nib file on the SD card and stream it into the
 * FPGA SDRAM track window, then pulse ack.
 */

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "ff.h"
#include "fpga_spi.h"
#include "fpga_sd.h"
#include "fpga_screen.h"
#include "disk.h"
#include "diskio_host.h"   /* SD/USB backend selection */
#include "usb_osal.h"      /* usb_osal_msleep */
#include "osd_console.h"   /* shared boot/status console */
#include "bflb_mtimer.h"   /* bflb_mtimer_get_time_us — load-latency timing */
#include "gcr_dsk.h"       /* on-the-fly .dsk/.do <-> 6-and-2 GCR nibble codec */
#include "settings.h"      /* persisted image overrides + boot preference */
#include "fwupdate.h"
#include "fpgaupdate.h"      /* firmware self-update (staged from this thread) */
#include "usbh_core.h"     /* USB supervisor: tree walk + stack recycle */
#include "usbh_hub.h"      /* port power-cycle kick for stalled hubs */
#include "bl616_glb.h"
#include "bl616_pds.h"

/* ---- Volume register map (must match bl616_spi_connector.sv 0x40-0x5F) ---- */
#define VOL_BASE(v)       (0x40u + (v) * 0x10u)
#define VOL_READY(v)      (VOL_BASE(v) + 0x0u)   /* W: volume ready */
#define VOL_MOUNTED(v)    (VOL_BASE(v) + 0x2u)   /* W: disk present */
#define VOL_READONLY(v)   (VOL_BASE(v) + 0x3u)   /* W: write-protected */
#define VOL_SIZE(v)       (VOL_BASE(v) + 0x4u)   /* W: 4 bytes LE, size in blocks */
#define VOL_LBA(v)        (VOL_BASE(v) + 0x8u)   /* R: 4 bytes LE, requested LBA */
#define VOL_BLKCNT(v)     (VOL_BASE(v) + 0xCu)   /* R: block count - 1 */
#define VOL_RD(v)         (VOL_BASE(v) + 0xDu)   /* R: read request pending */
#define VOL_WR(v)         (VOL_BASE(v) + 0xEu)   /* R: write request pending */
#define VOL_ACK(v)        (VOL_BASE(v) + 0xFu)   /* W: acknowledge (strobe) */

/* ---- ProDOS HDD volume registers (compact bank, bl616_spi_connector) ------
 * 7-bit reg space is full, so read/write meanings overlap per address:
 *   base+0  R: {wr, rd} request pending    W: CTL {readonly, mounted, ready}
 *   base+1  R: LBA low  (ProDOS block #)   W: SIZE low  (blocks)
 *   base+2  R: LBA high                    W: SIZE high
 *   base+3  R: -                           W: ACK (strobe)
 * Unit 0 at 0x26, unit 1 at 0x2A. */
#define HDD_BASE(u)       (0x26u + (u) * 4u)
#define HDD_REQ(u)        (HDD_BASE(u) + 0u)   /* R */
#define HDD_LBA_L(u)      (HDD_BASE(u) + 1u)   /* R */
#define HDD_LBA_H(u)      (HDD_BASE(u) + 2u)   /* R */
#define HDD_CTL(u)        (HDD_BASE(u) + 0u)   /* W */
#define HDD_SIZE_L(u)     (HDD_BASE(u) + 1u)   /* W */
#define HDD_SIZE_H(u)     (HDD_BASE(u) + 2u)   /* W */
#define HDD_ACK(u)        (HDD_BASE(u) + 3u)   /* W */
#define HDD_CTL_READY     0x01u
#define HDD_CTL_MOUNTED   0x02u
#define HDD_CTL_READONLY  0x04u

/* ---- SDRAM track windows (must match top.sv DISK_WORD_BASE + d*0x2000) ----
 * DISK_WORD_BASE = word 0x080000 = byte 0x200000; per-drive stride = 8KB.
 * HDD block windows follow at byte 0x204000, 512 bytes per unit. */
#define DISK_WINDOW_BASE    0x200000u
#define DISK_WINDOW_STRIDE  0x2000u
#define HDD_WINDOW_BASE     0x204000u
#define HDD_WINDOW_STRIDE   0x200u
#define SECTOR_BYTES        512u
#define MAX_TRACK_BYTES     0x1A00u   /* 6656 = 13 sectors */

#define NDRV 2   /* Disk II floppy drives */
#define NHDD 2   /* ProDOS HDD units      */

/* Per-drive image format:
 *   FMT_NIB — raw nibble track, streamed as-is
 *   FMT_DSK — sector image (16*256 B/track) that gcr_dsk nibblizes on load /
 *             de-nibblizes on flush; g_order[] gives the file's sector order
 *             (.dsk/.do = DOS 3.3, .po = ProDOS)
 * A .2mg is a 64-byte header wrapping one of the above; g_base[] carries the
 * payload's byte offset within the file (0 for bare images). */
typedef enum { FMT_NONE = 0, FMT_NIB, FMT_DSK } disk_fmt_t;

/* Candidate images per drive, tried in order (first that opens wins).
 * Sector formats take priority over .nib. OSD/config selection later. */
#define NCAND 5
static const char *const g_candidates[NDRV][NCAND] = {
    { "0:/disk1.dsk", "0:/disk1.do", "0:/disk1.po", "0:/disk1.2mg", "0:/disk1.nib" },
    { "0:/disk2.dsk", "0:/disk2.do", "0:/disk2.po", "0:/disk2.2mg", "0:/disk2.nib" },
};

static FATFS       g_fs;
static FIL         g_img[NDRV];
static bool        g_mounted[NDRV];
static bool        g_writable[NDRV];
static disk_fmt_t  g_fmt[NDRV];
static gcr_order_t g_order[NDRV];                /* sector order for FMT_DSK    */
static uint32_t    g_base[NDRV];                 /* payload offset (.2mg header)*/
static char        g_imgname[NDRV][SETTINGS_NAME_LEN + 4]; /* resolved image path */
static uint8_t     g_trackbuf[MAX_TRACK_BYTES];  /* nibble track (SDRAM window) */
static uint8_t     g_secbuf[DSK_TRACK_BYTES];    /* one sector track (16*256)   */

/* ProDOS HDD units: raw 512-byte block volumes (.hdv/.po/.2mg), served one
 * block at a time, LBA 1:1 into the image payload. */
static const char *const g_hdd_candidates[NHDD][3] = {
    { "0:/hdd1.hdv", "0:/hdd1.po", "0:/hdd1.2mg" },
    { "0:/hdd2.hdv", "0:/hdd2.po", "0:/hdd2.2mg" },
};
static FIL      g_hdd_img[NHDD];
static bool     g_hdd_mounted[NHDD];
static bool     g_hdd_writable[NHDD];
static uint32_t g_hdd_base[NHDD];       /* payload offset (.2mg header)  */
static uint32_t g_hdd_blocks[NHDD];     /* size in 512-byte blocks       */
static char     g_hdd_name[NHDD][SETTINGS_NAME_LEN + 4];
static uint8_t  g_blockbuf[SECTOR_BYTES];

static void fs_service(void);   /* async FS proxy step (defined below) */

/* Menu directory-listing request (see disk_list_begin/poll in disk.h). */
static volatile bool          g_list_req;
static volatile bool          g_list_done;
static const char *const     *g_list_exts;
static char                   g_list_path[SETTINGS_NAME_LEN + 4];
static disk_list_ent_t        g_list_ents[DISK_LIST_MAX];
static int                    g_list_count;

/* Case-insensitive extension test ("dsk", "do", ...). */
static bool has_ext(const char *name, const char *ext)
{
    size_t n = strlen(name), x = strlen(ext);
    if (n < x + 1 || name[n - x - 1] != '.')
        return false;
    for (size_t i = 0; i < x; i++)
        if ((name[n - x + i] | 0x20) != (ext[i] | 0x20))
            return false;
    return true;
}

/* Case-insensitive name compare for the directory listing sort. */
static int name_cmp(const char *a, const char *b)
{
    while (*a && *b) {
        int ca = *a | 0x20, cb = *b | 0x20;
        if (ca != cb)
            return ca - cb;
        a++; b++;
    }
    return (*a & 0xff) - (*b & 0xff);
}

/* Format + sector order from the filename extension. .2mg is resolved from its
 * header at mount time (see mount_drive). */
static disk_fmt_t detect_format(const char *name, gcr_order_t *order)
{
    *order = GCR_ORDER_DOS;
    if (has_ext(name, "nib"))
        return FMT_NIB;
    if (has_ext(name, "dsk") || has_ext(name, "do"))
        return FMT_DSK;
    if (has_ext(name, "po")) {
        *order = GCR_ORDER_PRODOS;
        return FMT_DSK;
    }
    return FMT_NONE;
}

/* Sniff the sector order of a bare .dsk (the extension nominally means DOS
 * 3.3 order, but many ProDOS disks circulate as ProDOS-order images named
 * .dsk). Detection per the classic CiderPress/AppleWin heuristics:
 *   - a DOS 3.3 VTOC at track 17 sector 0 (DOS-order file offset 0x11000):
 *     35 tracks, 16 sectors, 256 bytes/sector markers
 *   - else a ProDOS volume directory at block 2 (ProDOS-order file offset
 *     0x400): storage type $F header, entry_length $27, entries/block $0D
 * A DOS-order image of a ProDOS *filesystem* still sniffs as DOS order
 * (ProDOS blocks are not contiguous in a DOS-order file), which is correct —
 * the order describes the file layout, not the filesystem. Defaults to DOS
 * order when neither signature is found. */
static gcr_order_t sniff_dsk_order(FIL *f)
{
    uint8_t buf[256];
    UINT br = 0;

    if (f_lseek(f, 0x11000) == FR_OK &&
        f_read(f, buf, sizeof(buf), &br) == FR_OK && br == sizeof(buf)) {
        if (buf[0x34] == 35 && buf[0x35] == 16 &&
            buf[0x36] == 0x00 && buf[0x37] == 0x01)
            return GCR_ORDER_DOS;        /* DOS 3.3 VTOC found */
    }

    br = 0;
    if (f_lseek(f, 0x400) == FR_OK &&
        f_read(f, buf, sizeof(buf), &br) == FR_OK && br == sizeof(buf)) {
        if ((buf[0x04] >> 4) == 0xF && (buf[0x04] & 0x0F) >= 1 &&
            buf[0x23] == 0x27 && buf[0x24] == 0x0D)
            return GCR_ORDER_PRODOS;     /* ProDOS volume directory found */
    }

    return GCR_ORDER_DOS;
}

/* Parse a 2IMG (.2mg) header: 64-byte header, format word at 0x0C (0 = DOS
 * order, 1 = ProDOS order, 2 = NIB), payload offset at 0x18, length at 0x1C.
 * Only floppy-size payloads serve as Disk II volumes; block-device payloads
 * belong to the (future) hard-disk path. Returns the format or FMT_NONE. */
static disk_fmt_t parse_2mg(FIL *f, gcr_order_t *order, uint32_t *base,
                            uint32_t *paylen)
{
    uint8_t h[64];
    UINT br = 0;
    if (f_lseek(f, 0) != FR_OK || f_read(f, h, sizeof h, &br) != FR_OK ||
        br != sizeof h)
        return FMT_NONE;
    if (memcmp(h, "2IMG", 4) != 0)
        return FMT_NONE;

    uint32_t fmt = (uint32_t)h[0x0C] | ((uint32_t)h[0x0D] << 8) |
                   ((uint32_t)h[0x0E] << 16) | ((uint32_t)h[0x0F] << 24);
    uint32_t off = (uint32_t)h[0x18] | ((uint32_t)h[0x19] << 8) |
                   ((uint32_t)h[0x1A] << 16) | ((uint32_t)h[0x1B] << 24);
    uint32_t len = (uint32_t)h[0x1C] | ((uint32_t)h[0x1D] << 8) |
                   ((uint32_t)h[0x1E] << 16) | ((uint32_t)h[0x1F] << 24);
    if (off == 0)
        off = 64;   /* some creators leave the offset field 0 */

    *base   = off;
    *paylen = len;
    *order  = (fmt == 1) ? GCR_ORDER_PRODOS : GCR_ORDER_DOS;
    if (fmt == 2)
        return FMT_NIB;
    if (fmt <= 1)
        return FMT_DSK;
    return FMT_NONE;
}

static uint32_t reg_read32(uint8_t reg)
{
    return ((uint32_t)fpga_spi_reg_read(reg)) |
           ((uint32_t)fpga_spi_reg_read(reg + 1) << 8) |
           ((uint32_t)fpga_spi_reg_read(reg + 2) << 16) |
           ((uint32_t)fpga_spi_reg_read(reg + 3) << 24);
}

static void reg_write32(uint8_t reg, uint32_t val)
{
    fpga_spi_reg_write(reg + 0, (uint8_t)(val));
    fpga_spi_reg_write(reg + 1, (uint8_t)(val >> 8));
    fpga_spi_reg_write(reg + 2, (uint8_t)(val >> 16));
    fpga_spi_reg_write(reg + 3, (uint8_t)(val >> 24));
}

static void mount_drive(int v)
{
    g_mounted[v]  = false;
    g_writable[v] = false;
    g_fmt[v]      = FMT_NONE;
    g_order[v]    = GCR_ORDER_DOS;
    g_base[v]     = 0;
    fpga_spi_reg_write(VOL_READY(v), 0);
    fpga_spi_reg_write(VOL_MOUNTED(v), 0);

    /* Default display name (primary candidate) for the not-found log. */
    strncpy(g_imgname[v], g_candidates[v][0], sizeof(g_imgname[v]) - 1);
    g_imgname[v][sizeof(g_imgname[v]) - 1] = '\0';

    if (settings()->eject_mask & (1u << v))
        return;   /* ejected from the menu: leave unmounted */

    /* Candidate list: a persisted per-drive override (menu file picker) is
     * tried first, then the built-in names. First that opens AND resolves to
     * a servable format wins. Prefer read-write; fall back to read-only. */
    char ovr[SETTINGS_NAME_LEN + 4];
    const char *cands[NCAND + 1];
    int ncand = 0;
    if (settings()->disk_img[v][0]) {
        snprintf(ovr, sizeof(ovr), "0:/%s", settings()->disk_img[v]);
        cands[ncand++] = ovr;
    }
    for (int c = 0; c < NCAND; c++)
        cands[ncand++] = g_candidates[v][c];

    int opened = 0;
    for (int c = 0; c < ncand && !opened; c++) {
        const char *name = cands[c];
        bool rw;
        if (f_open(&g_img[v], name, FA_READ | FA_WRITE) == FR_OK)
            rw = true;
        else if (f_open(&g_img[v], name, FA_READ) == FR_OK)
            rw = false;
        else
            continue;

        disk_fmt_t  fmt;
        gcr_order_t order = GCR_ORDER_DOS;
        uint32_t    base  = 0;
        uint32_t    bytes = (uint32_t)f_size(&g_img[v]);

        if (has_ext(name, "2mg")) {
            uint32_t paylen = 0;
            fmt = parse_2mg(&g_img[v], &order, &base, &paylen);
            if (paylen)
                bytes = paylen;
            else if (bytes > base)
                bytes -= base;
        } else {
            fmt = detect_format(name, &order);
            /* Bare .dsk is ambiguous: sniff the actual sector order (.do and
             * .po stay explicit). */
            if (fmt == FMT_DSK && has_ext(name, "dsk"))
                order = sniff_dsk_order(&g_img[v]);
        }

        /* Only floppy-size payloads are Disk II volumes. Anything larger
         * (e.g. an 800K ProDOS .po) is a block device and belongs to the
         * hard-disk path — serving it here would nibblize garbage geometry
         * and hang the Apple's boot. */
        if ((fmt == FMT_DSK && bytes != DSK_TRACK_BYTES * 35u) ||
            (fmt == FMT_NIB && bytes != MAX_TRACK_BYTES * 35u)) {
            osd_log("DISK II: D%d %s not a 5.25 floppy (%lu B) - use HDD slot",
                    v + 1, name + 3, (unsigned long)bytes);
            fmt = FMT_NONE;
        }

        if (fmt == FMT_NONE) {
            f_close(&g_img[v]);
            continue;
        }

        g_writable[v] = rw;
        g_fmt[v]      = fmt;
        g_order[v]    = order;
        g_base[v]     = base;
        strncpy(g_imgname[v], name, sizeof(g_imgname[v]) - 1);
        g_imgname[v][sizeof(g_imgname[v]) - 1] = '\0';
        opened = 1;

        uint32_t blocks = bytes / SECTOR_BYTES;
        /* .dsk/.do/.po: 35 trk * 16 * 256 = 143360 B; .nib: 35 * 6656 =
         * 232960 B. VOL_SIZE is informational for a floppy. */
        osd_log("DISK II: D%d %s = %lu B (%s%s)", v + 1, g_imgname[v] + 3,
                (unsigned long)bytes,
                fmt == FMT_NIB ? "nib" :
                (order == GCR_ORDER_PRODOS ? "po" : "dsk"),
                base ? " 2mg" : "");
        reg_write32(VOL_SIZE(v), blocks);
        fpga_spi_reg_write(VOL_READONLY(v), g_writable[v] ? 0 : 1);
        fpga_spi_reg_write(VOL_MOUNTED(v), 1);
        fpga_spi_reg_write(VOL_READY(v), 1);
        g_mounted[v] = true;
    }
}

/* ---- ProDOS HDD unit mount: raw 512-byte blocks, LBA 1:1 ----------------- */
static void mount_hdd(int u)
{
    g_hdd_mounted[u]  = false;
    g_hdd_writable[u] = false;
    g_hdd_base[u]     = 0;
    g_hdd_blocks[u]   = 0;
    fpga_spi_reg_write(HDD_CTL(u), 0);

    strncpy(g_hdd_name[u], g_hdd_candidates[u][0], sizeof(g_hdd_name[u]) - 1);
    g_hdd_name[u][sizeof(g_hdd_name[u]) - 1] = '\0';

    if (settings()->eject_mask & (1u << (4 + u)))
        return;   /* ejected from the menu: leave unmounted */

    char ovr[SETTINGS_NAME_LEN + 4];
    const char *cands[4];
    int ncand = 0;
    if (settings()->hdd_img[u][0]) {
        snprintf(ovr, sizeof(ovr), "0:/%s", settings()->hdd_img[u]);
        cands[ncand++] = ovr;
    }
    for (int c = 0; c < 3; c++)
        cands[ncand++] = g_hdd_candidates[u][c];

    for (int c = 0; c < ncand; c++) {
        const char *name = cands[c];
        bool rw;
        if (f_open(&g_hdd_img[u], name, FA_READ | FA_WRITE) == FR_OK)
            rw = true;
        else if (f_open(&g_hdd_img[u], name, FA_READ) == FR_OK)
            rw = false;
        else
            continue;

        uint32_t base  = 0;
        uint32_t bytes = (uint32_t)f_size(&g_hdd_img[u]);

        if (has_ext(name, "2mg")) {
            /* Any ProDOS-order 2mg payload serves as a block device. */
            gcr_order_t order;
            uint32_t    paylen = 0;
            disk_fmt_t  fmt = parse_2mg(&g_hdd_img[u], &order, &base, &paylen);
            if (fmt != FMT_DSK || order != GCR_ORDER_PRODOS) {
                /* DOS-order / NIB payloads are floppies, not block devices */
                if (fmt == FMT_NONE || bytes < base) {
                    f_close(&g_hdd_img[u]);
                    continue;
                }
            }
            if (paylen)
                bytes = paylen;
            else
                bytes -= base;
        }
        /* .hdv / .po: raw ProDOS blocks from byte 0 */

        uint32_t blocks = bytes / SECTOR_BYTES;
        if (blocks == 0) {
            f_close(&g_hdd_img[u]);
            continue;
        }
        if (blocks > 0xFFFFu)
            blocks = 0xFFFFu;   /* ProDOS volumes cap at 65535 blocks (32 MB) */

        g_hdd_writable[u] = rw;
        g_hdd_base[u]     = base;
        g_hdd_blocks[u]   = blocks;
        strncpy(g_hdd_name[u], name, sizeof(g_hdd_name[u]) - 1);
        g_hdd_name[u][sizeof(g_hdd_name[u]) - 1] = '\0';

        fpga_spi_reg_write(HDD_SIZE_L(u), (uint8_t)blocks);
        fpga_spi_reg_write(HDD_SIZE_H(u), (uint8_t)(blocks >> 8));
        fpga_spi_reg_write(HDD_CTL(u), HDD_CTL_READY | HDD_CTL_MOUNTED |
                                       (rw ? 0 : HDD_CTL_READONLY));
        g_hdd_mounted[u] = true;
        return;
    }
}

/* Re-evaluate the storage backend and (re)mount the images. Triggered at
 * startup and whenever a USB stick is attached/removed. Prefers the USB stick
 * if present, otherwise the SD card. */
static volatile bool g_remount_req = true;
static volatile bool g_remounting  = false;   /* disk_remount() running */

/* Non-blocking console hide: disk_remount() schedules the "READY" screen to be
 * handed back to the Apple II after a readable delay, and disk_poll() performs
 * the hide when the time arrives. Doing this instead of msleep() keeps the 2 ms
 * disk task serving track loads throughout the delay — a blocking sleep here
 * freezes serving for the whole delay and hangs a boot that seeks into it.
 * 0 = nothing scheduled. */
static uint32_t g_hide_console_at_us = 0;

void disk_request_remount(void)
{
    g_remount_req = true;
}

/* ---- Disk II (re)mount, logged to the shared OSD console -------------------
 * Mount status is appended to the boot console (osd_console). The console is
 * shown while we look for the image(s); on a successful mount we hide it so the
 * screen returns to the Apple II, and on failure we leave it up so the message
 * can be read. */
static void disk_remount(void)
{
    osd_console_show();
    osd_log("DISK II: SEARCHING FOR STORAGE...");

    /* Tear down the previous mount. */
    for (int v = 0; v < NDRV; v++) {
        if (g_mounted[v])
            f_close(&g_img[v]);
        g_mounted[v]  = false;
        g_writable[v] = false;
        fpga_spi_reg_write(VOL_READY(v), 0);
        fpga_spi_reg_write(VOL_MOUNTED(v), 0);
    }
    for (int u = 0; u < NHDD; u++) {
        if (g_hdd_mounted[u])
            f_close(&g_hdd_img[u]);
        g_hdd_mounted[u] = false;
        fpga_spi_reg_write(HDD_CTL(u), 0);
    }
    f_mount(NULL, "0:", 0);

    bool usb_present = (g_msc_class != NULL);
    bool use_usb;
    switch (settings()->boot_pref) {
    case BOOT_PREF_USB: use_usb = true;  break;   /* wait for the stick */
    case BOOT_PREF_SD:  use_usb = false; break;
    default:            use_usb = usb_present;    /* AUTO */
    }
    if (use_usb && !usb_present) {
        osd_log("DISK II: WAITING FOR USB STORAGE (PREF)");
        return;   /* the USB attach hook triggers another remount */
    }
    disk_io_set_backend_usb(use_usb);
    osd_log(use_usb ? "DISK II: USB MASS STORAGE"
                    : "DISK II: SD CARD");

    FRESULT fr = f_mount(&g_fs, "0:", 1);
    if (fr != FR_OK) {
        if (use_usb) {
            /* FR=13 FR_NO_FILESYSTEM (not FAT / GPT scheme), FR=1 FR_DISK_ERR
             * (USB read path / block size), FR=3 FR_NOT_READY, etc. */
            osd_log("DISK II: USB MOUNT FAILED (FR=%d)", (int)fr);
            osd_log("DISK II: USB %lu BLK x %u B",
                    (unsigned long)disk_usb_block_count(),
                    (unsigned)disk_usb_block_size());
        } else {
            osd_log("DISK II: INSERT USB DRIVE WITH DISK1.DSK/.NIB");
        }
        return;   /* leave the console up so the message is visible */
    }

    int n_mounted = 0;
    for (int v = 0; v < NDRV; v++) {
        mount_drive(v);
        if (g_mounted[v]) {
            osd_log("DISK II: DRIVE %d %s MOUNTED (%s)", v + 1,
                    g_imgname[v] + 3, g_writable[v] ? "RW" : "RO");
            n_mounted++;
        } else {
            osd_log("DISK II: DRIVE %d %s NOT FOUND", v + 1, g_imgname[v] + 3);
        }
    }
    for (int u = 0; u < NHDD; u++) {
        mount_hdd(u);
        if (g_hdd_mounted[u]) {
            osd_log("HDD: UNIT %d %s MOUNTED (%lu BLK %s)", u + 1,
                    g_hdd_name[u] + 3, (unsigned long)g_hdd_blocks[u],
                    g_hdd_writable[u] ? "RW" : "RO");
            n_mounted++;
        }
    }

    if (n_mounted > 0) {
        osd_log("DISK II: READY - STARTING APPLE II");
        /* Hand the screen back after a readable delay, WITHOUT blocking: a
         * msleep here would freeze the 2 ms disk task and hang a boot that
         * seeks during the delay (observed as a ~1.54 s poll gap). */
        g_hide_console_at_us = (uint32_t)bflb_mtimer_get_time_us() + 1500000u;
    } else {
        osd_log("DISK II: NO DISK IMAGES ON VOLUME");
        /* leave the console up so the message is visible */
    }
}

void disk_init(void)
{
    fpga_sd_init();   /* SD tunnel defaults; mount happens on the first poll */
}

static void serve_drive(int v)
{
    if (!g_mounted[v])
        return;

    uint8_t rd = fpga_spi_reg_read(VOL_RD(v)) & 0x01;
    uint8_t wr = fpga_spi_reg_read(VOL_WR(v)) & 0x01;
    if (!rd && !wr)
        return;   /* nothing pending */

    uint32_t lba   = reg_read32(VOL_LBA(v));
    uint32_t nblk  = (uint32_t)fpga_spi_reg_read(VOL_BLKCNT(v)) + 1u;
    uint32_t nbyte = nblk * SECTOR_BYTES;
    if (nbyte > MAX_TRACK_BYTES)
        nbyte = MAX_TRACK_BYTES;

    uint32_t addr = DISK_WINDOW_BASE + (uint32_t)v * DISK_WINDOW_STRIDE;

    /* Log disk activity to the console BUFFER on track change (a boot re-polling
     * the same track must not spam). Does NOT force the console visible — the
     * Apple II keeps the screen so the booted disk is actually usable; press
     * Select to review the track log. */
    {
        static int s_last_trk[NDRV] = { -1, -1 };
        int trk = (int)(lba / 13u);
        if (trk != s_last_trk[v]) {
            s_last_trk[v] = trk;
            osd_log("DISK II: D%d %s TRK %d (LBA %lu N%lu)", v + 1,
                    wr ? "WR" : "RD", trk, (unsigned long)lba, (unsigned long)nblk);
        }
    }

    if (wr) {
        /* Flush a dirty track: SDRAM window -> image file. */
        if (g_writable[v]) {
            for (uint32_t off = 0; off < nbyte; off += SECTOR_BYTES) {
                uint32_t chunk = nbyte - off;
                if (chunk > SECTOR_BYTES)
                    chunk = SECTOR_BYTES;
                fpga_spi_xfer_read(FPGA_SPACE_SDRAM, addr + off,
                                   g_trackbuf + off, (uint16_t)chunk);
            }
            if (g_fmt[v] == FMT_DSK) {
                /* Decode the (possibly partly rewritten) nibble track back to
                 * file-order sectors. Preload the current on-file track so any
                 * sector that fails to decode keeps its existing bytes; gate the
                 * write on the found-mask so a bad decode never corrupts the
                 * image. */
                uint32_t track = lba / 13u;
                FSIZE_t  fpos  = (FSIZE_t)g_base[v] +
                                 (FSIZE_t)track * DSK_TRACK_BYTES;
                UINT br = 0;
                if (f_lseek(&g_img[v], fpos) == FR_OK)
                    f_read(&g_img[v], g_secbuf, DSK_TRACK_BYTES, &br);
                if (br < DSK_TRACK_BYTES)
                    memset(g_secbuf + br, 0, DSK_TRACK_BYTES - br);
                uint16_t mask = gcr_decode_dos_track(g_trackbuf, MAX_TRACK_BYTES,
                                                     g_order[v], g_secbuf);
                if (mask != 0) {
                    UINT bw = 0;
                    if (f_lseek(&g_img[v], fpos) == FR_OK) {
                        f_write(&g_img[v], g_secbuf, DSK_TRACK_BYTES, &bw);
                        f_sync(&g_img[v]);
                    }
                }
                if (mask != 0xFFFF)
                    osd_log("DISK II: D%d TRK%lu wr partial mask=%04X",
                            v + 1, (unsigned long)track, (unsigned)mask);
            } else {
                UINT bw = 0;
                if (f_lseek(&g_img[v], (FSIZE_t)g_base[v] +
                                       (FSIZE_t)lba * SECTOR_BYTES) == FR_OK) {
                    f_write(&g_img[v], g_trackbuf, nbyte, &bw);
                    f_sync(&g_img[v]);
                }
            }
        }
    } else {
        /* Load the requested track: image file -> SDRAM window. */
        uint32_t track = lba / 13u;
        if (g_fmt[v] == FMT_DSK) {
            /* Read this track's 16*256 file-order sectors and nibblize them
             * into the 6-and-2 GCR stream the window expects. */
            UINT br = 0;
            if (f_lseek(&g_img[v], (FSIZE_t)g_base[v] +
                                   (FSIZE_t)track * DSK_TRACK_BYTES) == FR_OK)
                f_read(&g_img[v], g_secbuf, DSK_TRACK_BYTES, &br);
            if (br < DSK_TRACK_BYTES)
                memset(g_secbuf + br, 0, DSK_TRACK_BYTES - br);
            gcr_encode_dos_track(g_secbuf, (uint8_t)track, DSK_DEFAULT_VOLUME,
                                 g_order[v], g_trackbuf, MAX_TRACK_BYTES);
        } else {
            /* .nib: raw nibble stream, streamed as-is. */
            UINT br = 0;
            if (f_lseek(&g_img[v], (FSIZE_t)g_base[v] +
                                   (FSIZE_t)lba * SECTOR_BYTES) == FR_OK)
                f_read(&g_img[v], g_trackbuf, nbyte, &br);
            if (br < nbyte) {
                /* EOF: a zero-filled track has no sync/prologue nibbles, so RWTS
                 * finds nothing and DOS I/O-errors at this same track every boot
                 * — pinpoints a truncated/short .nib. */
                osd_console_show();
                osd_log("DISK II: TRK%lu SHORT br=%lu/%lu (EOF) -> zero-fill",
                        (unsigned long)track,
                        (unsigned long)br, (unsigned long)nbyte);
                memset(g_trackbuf + br, 0, nbyte - br);
            }
        }

        for (uint32_t off = 0; off < nbyte; off += SECTOR_BYTES) {
            uint32_t chunk = nbyte - off;
            if (chunk > SECTOR_BYTES)
                chunk = SECTOR_BYTES;
            fpga_spi_xfer_write(FPGA_SPACE_SDRAM, addr + off,
                                g_trackbuf + off, (uint16_t)chunk);
        }
    }

    fpga_spi_reg_write(VOL_ACK(v), 1);   /* request serviced — release the head */
}

/* Serve one ProDOS HDD unit: raw 512-byte blocks, LBA 1:1 into the image
 * payload, one block per request through the unit's SDRAM window. */
static void serve_hdd(int u)
{
    if (!g_hdd_mounted[u])
        return;

    uint8_t req = fpga_spi_reg_read(HDD_REQ(u)) & 0x03;
    if (!req)
        return;   /* nothing pending */

    uint32_t lba = (uint32_t)fpga_spi_reg_read(HDD_LBA_L(u)) |
                   ((uint32_t)fpga_spi_reg_read(HDD_LBA_H(u)) << 8);
    uint32_t addr = HDD_WINDOW_BASE + (uint32_t)u * HDD_WINDOW_STRIDE;
    FSIZE_t  fpos = (FSIZE_t)g_hdd_base[u] + (FSIZE_t)lba * SECTOR_BYTES;

    if (req & 0x02) {
        /* write: SDRAM window -> image file */
        if (g_hdd_writable[u] && lba < g_hdd_blocks[u]) {
            UINT bw = 0;
            fpga_spi_xfer_read(FPGA_SPACE_SDRAM, addr, g_blockbuf, SECTOR_BYTES);
            if (f_lseek(&g_hdd_img[u], fpos) == FR_OK) {
                f_write(&g_hdd_img[u], g_blockbuf, SECTOR_BYTES, &bw);
                f_sync(&g_hdd_img[u]);
            }
        }
    } else {
        /* read: image file -> SDRAM window */
        UINT br = 0;
        if (lba < g_hdd_blocks[u] &&
            f_lseek(&g_hdd_img[u], fpos) == FR_OK)
            f_read(&g_hdd_img[u], g_blockbuf, SECTOR_BYTES, &br);
        if (br < SECTOR_BYTES)
            memset(g_blockbuf + br, 0, SECTOR_BYTES - br);
        fpga_spi_xfer_write(FPGA_SPACE_SDRAM, addr, g_blockbuf, SECTOR_BYTES);
    }

    fpga_spi_reg_write(HDD_ACK(u), 1);   /* request serviced */
}


/* Exported from CherryUSB core, no public prototypes. */
extern int  usbh_enumerate(struct usbh_hubport *hport);
extern void usbh_hubport_release(struct usbh_hubport *hport);

/* DMA target: MUST be in the no-cache section like the driver's g_hub_buf,
 * or the CPU reads back a stale cached line (all zeros) after the transfer. */
static USB_NOCACHE_RAM_SECTION USB_MEM_ALIGNX uint8_t sup_status_buf[32];

/* GET_PORT_STATUS clone of the hub driver's static helper. */
static int sup_get_portstatus(struct usbh_hub *hub, uint8_t port,
                              struct hub_port_status *ps)
{
    struct usb_setup_packet *setup = hub->parent->setup;
    setup->bmRequestType = USB_REQUEST_DIR_IN | USB_REQUEST_CLASS |
                           USB_REQUEST_RECIPIENT_OTHER;
    setup->bRequest = HUB_REQUEST_GET_STATUS;
    setup->wValue = 0;
    setup->wIndex = port;
    setup->wLength = 4;
    int ret = usbh_control_transfer(hub->parent, setup, sup_status_buf);
    if (ret < 0)
        return ret;
    memcpy(ps, sup_status_buf, 4);
    return 0;
}

/* Enumerate devices sitting on already-powered hub ports. CherryUSB's hub
 * driver only reacts to CHANGE events from the hub's interrupt endpoint;
 * after a firmware jump-restart the hub's ports are long powered and the
 * settled devices never generate one (and this hub has no real per-port
 * power switching, so a power-cycle kick does nothing). Do what the driver
 * would do on a connect change: reset the port, then build and enumerate
 * the child hubport (mirrors usbh_hub_events' connect tail). */
static int usb_hub_adopt_ports(struct usbh_hub *hub)
{
    int adopted = 0;
    struct hub_port_status ps;

    for (uint8_t port = 0; port < hub->nports; port++) {
        struct usbh_hubport *child = &hub->child[port];
        if (child->connected)
            continue;
        if (sup_get_portstatus(hub, port + 1, &ps) < 0)
            continue;
        if (!(ps.wPortStatus & HUB_PORT_STATUS_CONNECTION))
            continue;

        osd_log("USB: ADOPTING HUB PORT %d", port + 1);
        if (usbh_hub_set_feature(hub, port + 1, HUB_PORT_FEATURE_RESET) < 0)
            continue;
        usb_osal_msleep(150);
        if (sup_get_portstatus(hub, port + 1, &ps) < 0)
            continue;
        if ((ps.wPortStatus & HUB_PORT_STATUS_RESET) ||
            !(ps.wPortStatus & HUB_PORT_STATUS_ENABLE)) {
            osd_log("USB: PORT %d NOT ENABLED (%04X)",
                    port + 1, ps.wPortStatus);
            continue;
        }
        if (ps.wPortChange & HUB_PORT_STATUS_C_RESET)
            usbh_hub_clear_feature(hub, port + 1, HUB_PORT_FEATURE_C_RESET);
        if (ps.wPortChange & HUB_PORT_STATUS_C_CONNECTION)
            usbh_hub_clear_feature(hub, port + 1,
                                   HUB_PORT_FEATURE_C_CONNECTION);

        uint8_t speed = (ps.wPortStatus & HUB_PORT_STATUS_HIGH_SPEED)
                            ? USB_SPEED_HIGH
                            : (ps.wPortStatus & HUB_PORT_STATUS_LOW_SPEED)
                                  ? USB_SPEED_LOW
                                  : USB_SPEED_FULL;

        usbh_hubport_release(child);
        memset(child, 0, sizeof(*child));
        child->parent = hub;
        child->depth = (hub->parent ? hub->parent->depth : 0) + 1;
        child->connected = true;
        child->port = port + 1;
        child->speed = speed;
        child->bus = hub->bus;
        child->mutex = usb_osal_mutex_create();

        if (usbh_enumerate(child) < 0) {
            usbh_hubport_release(child);
            osd_log("USB: PORT %d ENUM FAILED", port + 1);
        } else {
            adopted++;
        }
    }
    return adopted;
}

/* Find a registered hub whose ports have zero connected children — the
 * signature of the silent post-restart stall: CherryUSB's hub driver only
 * reacts to CHANGE events on the hub's interrupt endpoint, and a hub whose
 * ports stayed powered with settled devices never generates any. */
static struct usbh_hub *find_stalled_hub(struct usbh_hub *hub)
{
    if (!hub)
        return NULL;
    int kids = 0;
    for (int i = 0; i < CONFIG_USBHOST_MAX_EHPORTS; i++) {
        struct usbh_hubport *p = &hub->child[i];
        if (!p->connected)
            continue;
        kids++;
        if (p->self) {
            struct usbh_hub *deeper = find_stalled_hub(p->self);
            if (deeper)
                return deeper;
        }
    }
    return (!hub->is_roothub && hub->connected && kids == 0) ? hub : NULL;
}

/* Count connected non-hub devices under a (root)hub — 0 while enumeration
 * of everything useful has failed, whatever the topology. */
static int usb_leaf_count(struct usbh_hub *hub)
{
    int n = 0;
    if (!hub)
        return 0;
    for (int i = 0; i < CONFIG_USBHOST_MAX_EHPORTS; i++) {
        struct usbh_hubport *p = &hub->child[i];
        if (!p->connected)
            continue;
        if (p->self)
            n += usb_leaf_count(p->self);
        else
            n++;
    }
    return n;
}
void disk_poll(void)
{
    if (g_remount_req) {
        g_remount_req = false;
        g_remounting  = true;
        disk_remount();
        g_remounting  = false;
    }

    /* Non-blocking console hide (scheduled by disk_remount on a good mount). */
    if (g_hide_console_at_us &&
        (int32_t)((uint32_t)bflb_mtimer_get_time_us() - g_hide_console_at_us) >= 0) {
        g_hide_console_at_us = 0;
        osd_console_hide();
    }

    /* Apple II reset release: the FPGA holds the Apple II in RESET from
     * power-on (reg 0x2E, bl616_spi_connector) so the autoboot slot scan does
     * not run before storage is up. Release as soon as a (re)mount has found
     * at least one volume, or after a deadline so a machine with no media
     * still boots. The FPGA has its own 15 s backstop should we never write. */
    {
        static bool s_released = false;
        if (!s_released) {
            bool any = false;
            for (int v = 0; v < NDRV; v++) any = any || g_mounted[v];
            for (int u = 0; u < NHDD; u++) any = any || g_hdd_mounted[u];
            if ((any && !g_remount_req) ||
                bflb_mtimer_get_time_us() > 7000000u) {
                /* Program the slot map JUST before the release — this late in
                 * boot the SPI link is proven good (the mounts above ran over
                 * it; writes issued from early main() were getting lost), and
                 * the Apple II is still held in reset so the reconfig is
                 * race-free. The registers double as the readable mirror the
                 * menu's "NOW:" column uses. 0xFF = hardware default. */
                for (int i = 0; i < 8; i++) {
                    uint8_t c = settings()->slot_cards[i];
                    if (c == 0xFF)
                        c = settings_slot_hw_defaults[i];
                    fpga_spi_reg_write((uint8_t)(0x60 + i), c);
                }
                fpga_spi_reg_write(0x6B, 1);   /* slotmaker reconfig strobe */
                osd_log("SLOTS: %d %d %d %d %d %d %d %d",
                        fpga_spi_reg_read(0x60), fpga_spi_reg_read(0x61),
                        fpga_spi_reg_read(0x62), fpga_spi_reg_read(0x63),
                        fpga_spi_reg_read(0x64), fpga_spi_reg_read(0x65),
                        fpga_spi_reg_read(0x66), fpga_spi_reg_read(0x67));

                fpga_spi_reg_write(0x2E, 1);   /* A2_RST_RELEASE */
                s_released = true;
                osd_log("A2: RESET RELEASED%s", any ? "" : " (NO MEDIA)");
            }
        }
    }

    /* Async directory listing for the menu (FatFS is not re-entrant, so the
     * scan runs here, in the thread that owns the filesystem). Two passes so
     * directories sort before files. */
    fs_service();

    if (g_list_req) {
        g_list_count = 0;
        for (int pass = 0; pass < 2; pass++) {
            DIR dir;
            FILINFO fno;
            if (f_opendir(&dir, g_list_path) != FR_OK)
                break;
            while (g_list_count < DISK_LIST_MAX) {
                if (f_readdir(&dir, &fno) != FR_OK || fno.fname[0] == '\0')
                    break;
                if (fno.fname[0] == '.' || fno.fname[0] == '_')
                    continue;
                bool is_dir = (fno.fattrib & AM_DIR) != 0;
                if ((pass == 0) != is_dir)
                    continue;
                if (!is_dir) {
                    bool match = false;
                    for (int e = 0; g_list_exts[e] && !match; e++)
                        match = has_ext(fno.fname, g_list_exts[e]);
                    if (!match)
                        continue;
                }
                if (strlen(fno.fname) >= sizeof(g_list_ents[0].name))
                    continue;   /* name too long to select later */
                disk_list_ent_t *e = &g_list_ents[g_list_count++];
                snprintf(e->name, sizeof(e->name), "%s", fno.fname);
                e->is_dir = is_dir;
            }
            f_closedir(&dir);
        }
        /* Alphabetize within each group (the two passes already put
         * directories first). FAT returns creation order, which makes big
         * game folders unnavigable. Insertion sort: n <= DISK_LIST_MAX. */
        for (int i = 1; i < g_list_count; i++) {
            disk_list_ent_t tmp = g_list_ents[i];
            int j = i;
            while (j > 0 && g_list_ents[j - 1].is_dir == tmp.is_dir &&
                   name_cmp(g_list_ents[j - 1].name, tmp.name) > 0) {
                g_list_ents[j] = g_list_ents[j - 1];
                j--;
            }
            g_list_ents[j] = tmp;
        }
        g_list_req  = false;
        g_list_done = true;
    }

    for (int v = 0; v < NDRV; v++)
        serve_drive(v);
    for (int u = 0; u < NHDD; u++)
        serve_hdd(u);

    /* Firmware self-update: staged one chunk per poll (FatFS + flash both
     * belong to this thread); the commit phase never returns. */
    fwupdate_poll();
    fpgaupdate_poll();

    /* USB enumeration supervisor. The jump-restart path (fwupdate) re-inits
     * a USB stack whose devices are already up and settled, and CherryUSB's
     * bring-up intermittently loses the race: the port connects (and even
     * the hub can enumerate) but downstream devices never appear, silently.
     * Detect "something on the port but zero usable devices" sustained for
     * 8 s and recycle the whole stack (deinit -> USB block reset -> PHY off
     * -> init). Harmless on cold boots: devices enumerate long before the
     * trigger. Capped so a genuinely empty hub doesn't recycle forever. */
    {
        static uint32_t sup_cnt;
        static int      stall_s, attempts;
        if (++sup_cnt >= 500) {          /* ~1 s of 2 ms polls */
            sup_cnt = 0;
            uint32_t portsc = *(volatile uint32_t *)(0x20072030u);
            int leaves = usb_leaf_count(&g_usbhost_bus[0].hcd.roothub);
            if ((portsc & 1u) && leaves == 0)
                stall_s++;
            else {
                stall_s = 0;
                if (leaves > 0)
                    attempts = 0;
            }
            if (stall_s >= 8 && attempts < 5) {
                attempts++;
                stall_s = 0;
                struct usbh_hub *stalled =
                    find_stalled_hub(&g_usbhost_bus[0].hcd.roothub);
                if (stalled && attempts <= 2) {
                    osd_log("USB: ENUM STALLED - ADOPT %d/5", attempts);
                    int n = usb_hub_adopt_ports(stalled);
                    osd_log("USB: ADOPTED %d DEVICE(S)", n);
                } else if (attempts <= 4) {
                    /* Real power cycle for the downstream tree: >1 s VBUS
                     * drop fully discharges the hub (a short brownout
                     * zombies its port controller: EP0 alive, all ports
                     * report unpowered, SET PORT_POWER ignored). Reconnect
                     * then arrives as a genuine root-port connect change
                     * and the whole tree enumerates as on a cold boot. */
                    osd_log("USB: ENUM STALLED - VBUS CYCLE %d/5", attempts);
                    volatile uint32_t *otg =
                        (volatile uint32_t *)(0x20072080u);
                    uint32_t v = *otg;
                    v |= (1u << 5);            /* USB_A_BUS_DROP_HOV */
                    v &= ~(1u << 4);           /* USB_A_BUS_REQ_HOV  */
                    *otg = v;
                    usb_osal_msleep(1200);
                    v = *otg;
                    v &= ~(1u << 5);
                    v |= (1u << 4);
                    *otg = v;
                } else {
                    osd_log("USB: ENUM STALLED - RECYCLE %d/5", attempts);
                    usbh_deinitialize(0);
                    GLB_AHB_MCU_Software_Reset(GLB_AHB_MCU_SW_EXT_USB);
                    PDS_Turn_Off_USB();
                    usb_osal_msleep(100);
                    usbh_initialize(0, 0x20072000u);
                }
            }
        }
    }

}

/* ---- menu accessors (see disk.h) ----------------------------------------- */
void disk_get_floppy_info(int v, disk_info_t *out)
{
    memset(out, 0, sizeof(*out));
    if (v < 0 || v >= NDRV)
        return;
    out->mounted  = g_mounted[v];
    out->writable = g_writable[v];
    {   /* display the basename (paths can exceed the label width) */
        const char *n = g_imgname[v][0] ? g_imgname[v] + 3 : "";
        const char *slash = strrchr(n, '/');
        snprintf(out->name, sizeof(out->name), "%s", slash ? slash + 1 : n);
    }
    if (g_mounted[v])
        snprintf(out->detail, sizeof(out->detail), "%s %s",
                 g_fmt[v] == FMT_NIB ? "NIB" :
                 (g_order[v] == GCR_ORDER_PRODOS ? "PO" : "DSK"),
                 g_writable[v] ? "RW" : "RO");
}

void disk_get_hdd_info(int u, disk_info_t *out)
{
    memset(out, 0, sizeof(*out));
    if (u < 0 || u >= NHDD)
        return;
    out->mounted  = g_hdd_mounted[u];
    out->writable = g_hdd_writable[u];
    {
        const char *n = g_hdd_name[u][0] ? g_hdd_name[u] + 3 : "";
        const char *slash = strrchr(n, '/');
        snprintf(out->name, sizeof(out->name), "%s", slash ? slash + 1 : n);
    }
    if (g_hdd_mounted[u])
        snprintf(out->detail, sizeof(out->detail), "%luBLK %s",
                 (unsigned long)g_hdd_blocks[u],
                 g_hdd_writable[u] ? "RW" : "RO");
}

bool disk_backend_is_usb(void)
{
    return g_msc_class != NULL;   /* mirrors the active-backend choice */
}

bool disk_remount_pending(void)
{
    return g_remount_req || g_remounting;
}

/* ---- async FS proxy (see disk.h) ---------------------------------------- */
#define FS_IDLE 0
#define FS_PEND 1
#define FS_DONE 2
static fs_req_t *volatile g_fs_req;
static volatile int       g_fs_state = FS_IDLE;
static volatile int       g_fs_fr;
static FIL                g_fs_fil;
static DIR                g_fs_dir;
static bool               g_fs_fil_open, g_fs_dir_open;

int disk_fs_request(fs_req_t *r)
{
    /* single submitter (ftpd thread); serialize defensively anyway */
    while (g_fs_state != FS_IDLE)
        usb_osal_msleep(1);
    r->out = 0;
    g_fs_req = r;
    g_fs_state = FS_PEND;
    for (int waited = 0; g_fs_state != FS_DONE; waited++) {
        if (waited > 30000)            /* 30 s: something is very wrong */
            return -1;
        usb_osal_msleep(1);
    }
    g_fs_state = FS_IDLE;
    return g_fs_fr;
}

bool disk_path_mounted(const char *path)
{
    char full[SETTINGS_NAME_LEN + 4];
    snprintf(full, sizeof(full), "0:/%s", path);
    for (int v = 0; v < NDRV; v++)
        if (g_fmt[v] != FMT_NONE && !strcasecmp(full, g_imgname[v]))
            return true;
    for (int u = 0; u < NHDD; u++)
        if (g_hdd_name[u][0] && !strcasecmp(full, g_hdd_name[u]))
            return true;
    return false;
}

/* Execute one bounded step of the pending FS job (disk thread only). READ
 * and WRITE move at most one r->len chunk (<=4 KB from ftpd) per poll so
 * track serving keeps its cadence; everything else completes in one step. */
static void fs_service(void)
{
    fs_req_t *r = g_fs_req;
    if (g_fs_state != FS_PEND || !r)
        return;
    char full[SETTINGS_NAME_LEN + 4];
    FRESULT fr = FR_OK;
    UINT n = 0;

    switch (r->op) {
    case FSOP_OPEN_R:
    case FSOP_OPEN_W:
        if (g_fs_fil_open) {
            f_close(&g_fs_fil);
            g_fs_fil_open = false;
        }
        snprintf(full, sizeof(full), "0:/%s", r->path);
        fr = f_open(&g_fs_fil, full,
                    r->op == FSOP_OPEN_R ? FA_READ
                                         : FA_WRITE | FA_CREATE_ALWAYS);
        g_fs_fil_open = (fr == FR_OK);
        if (fr == FR_OK)
            r->size = (uint32_t)f_size(&g_fs_fil);
        break;
    case FSOP_READ:
        fr = g_fs_fil_open ? f_read(&g_fs_fil, r->buf, r->len, &n)
                           : FR_NOT_ENABLED;
        r->out = n;
        break;
    case FSOP_WRITE:
        fr = g_fs_fil_open ? f_write(&g_fs_fil, r->buf, r->len, &n)
                           : FR_NOT_ENABLED;
        r->out = n;
        break;
    case FSOP_CLOSE:
        if (g_fs_fil_open) {
            fr = f_close(&g_fs_fil);
            g_fs_fil_open = false;
        }
        break;
    case FSOP_DELETE:
    case FSOP_MKDIR:
    case FSOP_RMDIR:
        snprintf(full, sizeof(full), "0:/%s", r->path);
        fr = r->op == FSOP_DELETE ? f_unlink(full)
           : r->op == FSOP_MKDIR  ? f_mkdir(full)
                                  : f_unlink(full);   /* rmdir==unlink */
        break;
    case FSOP_RENAME: {
        char full2[SETTINGS_NAME_LEN + 4];
        snprintf(full, sizeof(full), "0:/%s", r->path);
        snprintf(full2, sizeof(full2), "0:/%s", r->path2);
        fr = f_rename(full, full2);
        break;
    }
    case FSOP_STAT: {
        FILINFO fno;
        snprintf(full, sizeof(full), "0:/%s", r->path);
        if (!r->path[0]) {             /* volume root */
            r->size = 0;
            r->attr = AM_DIR;
            fr = FR_OK;
            break;
        }
        fr = f_stat(full, &fno);
        if (fr == FR_OK) {
            r->size  = (uint32_t)fno.fsize;
            r->attr  = fno.fattrib;
            r->fdate = fno.fdate;
            r->ftime = fno.ftime;
        }
        break;
    }
    case FSOP_LIST_OPEN:
        if (g_fs_dir_open) {
            f_closedir(&g_fs_dir);
            g_fs_dir_open = false;
        }
        snprintf(full, sizeof(full), "0:/%s", r->path);
        fr = f_opendir(&g_fs_dir, full);
        g_fs_dir_open = (fr == FR_OK);
        break;
    case FSOP_LIST_NEXT: {
        FILINFO fno;
        r->name[0] = 0;
        fr = g_fs_dir_open ? f_readdir(&g_fs_dir, &fno) : FR_NOT_ENABLED;
        if (fr == FR_OK && fno.fname[0]) {
            snprintf(r->name, sizeof(r->name), "%s", fno.fname);
            r->size  = (uint32_t)fno.fsize;
            r->attr  = fno.fattrib;
            r->fdate = fno.fdate;
            r->ftime = fno.ftime;
        }
        break;
    }
    case FSOP_LIST_CLOSE:
        if (g_fs_dir_open) {
            f_closedir(&g_fs_dir);
            g_fs_dir_open = false;
        }
        break;
    default:
        fr = FR_INVALID_PARAMETER;
        break;
    }

    g_fs_fr = fr;
    g_fs_state = FS_DONE;
}

void disk_list_begin(const char *path, const char *const *exts)
{
    g_list_done = false;
    g_list_exts = exts;
    snprintf(g_list_path, sizeof(g_list_path), "0:/%s", path ? path : "");
    g_list_req  = true;           /* serviced by the next disk_poll */
}

int disk_list_poll(disk_list_ent_t *ents, int max)
{
    if (!g_list_done)
        return -1;
    int n = g_list_count < max ? g_list_count : max;
    memcpy(ents, g_list_ents, (size_t)n * sizeof(disk_list_ent_t));
    return n;
}
